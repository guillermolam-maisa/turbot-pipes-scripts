#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

HOME_DIR="${HOME:-$(pwd)}"
AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-${HOME_DIR}/.aws/config}"
PROFILE_SELECTOR="${PROFILE_SELECTOR:-admin_only}"
DISCOVERY_ROOT="${DISCOVERY_ROOT:-/workspace/powerpipe/results/discovery}"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="${DISCOVERY_ROOT}/${STAMP}"
LATEST_LINK="${DISCOVERY_ROOT}/latest"
SUMMARY_FILE="${RUN_DIR}/summary.txt"
CLOUDTRAIL_TSV="${RUN_DIR}/cloudtrail.tsv"
S3_LOGGING_TSV="${RUN_DIR}/s3_server_access_logging.tsv"
PROFILE_TSV="${RUN_DIR}/profiles.tsv"
DISCOVERY_S3_BUCKET_LIMIT_PER_PROFILE="${DISCOVERY_S3_BUCKET_LIMIT_PER_PROFILE:-250}"
AWS_RETRY_ATTEMPTS="${AWS_RETRY_ATTEMPTS:-4}"
AWS_RETRY_BASE_DELAY="${AWS_RETRY_BASE_DELAY:-2}"

log() { printf '%s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: Missing command: $1"
    exit 1
  }
}

profile_selected() {
  local profile_name
  profile_name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "${PROFILE_SELECTOR}" in
    all)
      return 0
      ;;
    admin_only)
      [[ "${profile_name}" == *administratoraccess* ]]
      ;;
    *)
      [[ "${profile_name}" == *"${PROFILE_SELECTOR}"* ]]
      ;;
  esac
}

aws_retry_capture() {
  local attempt=1
  local delay="${AWS_RETRY_BASE_DELAY}"
  local output
  local rc

  while true; do
    if output="$("$@" 2>/dev/null)"; then
      printf '%s' "${output}"
      return 0
    fi

    rc=$?
    if (( attempt >= AWS_RETRY_ATTEMPTS )); then
      return "${rc}"
    fi

    sleep "${delay}"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

safe_text() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" == "None" || "${value}" == "null" ]]; then
    printf '%s' ""
  else
    printf '%s' "${value}"
  fi
}

append_cloudtrail_rows() {
  local profile_name="$1"
  local account_id="$2"
  local rows="$3"
  local line trail_name bucket_name bucket_prefix home_region multi_region is_org

  [[ -n "${rows}" ]] || return 0

  while IFS=$'\t' read -r trail_name bucket_name bucket_prefix home_region multi_region is_org; do
    [[ -n "${trail_name}" && -n "${bucket_name}" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${profile_name}" \
      "${account_id}" \
      "$(safe_text "${trail_name}")" \
      "$(safe_text "${bucket_name}")" \
      "$(safe_text "${bucket_prefix}")" \
      "$(safe_text "${home_region}")" \
      "$(safe_text "${multi_region}")" \
      >> "${CLOUDTRAIL_TSV}"
  done <<< "${rows}"
}

append_s3_logging_row() {
  local profile_name="$1"
  local account_id="$2"
  local bucket_name="$3"
  local bucket_region="$4"
  local target_bucket="$5"
  local target_prefix="$6"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${profile_name}" \
    "${account_id}" \
    "$(safe_text "${bucket_name}")" \
    "$(safe_text "${bucket_region}")" \
    "$(safe_text "${target_bucket}")" \
    "$(safe_text "${target_prefix}")" \
    >> "${S3_LOGGING_TSV}"
}

update_latest_link() {
  local tmp_link="${DISCOVERY_ROOT}/latest.tmp"
  local link_target
  link_target="$(basename "${RUN_DIR}")"
  rm -f "${tmp_link}"
  ln -s "${link_target}" "${tmp_link}" || return 1
  rm -f "${LATEST_LINK}"
  mv "${tmp_link}" "${LATEST_LINK}"
}

need_cmd aws
need_cmd date
need_cmd ln
need_cmd mkdir
need_cmd mv
need_cmd rm
need_cmd sed
need_cmd tr

[[ -f "${AWS_CONFIG_FILE}" ]] || {
  log "ERROR: AWS config not found: ${AWS_CONFIG_FILE}"
  exit 1
}

mkdir -p "${RUN_DIR}"
printf 'profile\taccount_id\trole_arn\tselector\n' > "${PROFILE_TSV}"
printf 'profile\taccount_id\ttrail_name\tbucket\tprefix\thome_region\tis_multi_region\n' > "${CLOUDTRAIL_TSV}"
printf 'profile\taccount_id\tsource_bucket\tsource_region\ttarget_bucket\ttarget_prefix\n' > "${S3_LOGGING_TSV}"

selected_count=0
usable_profiles=0
cloudtrail_rows=0
s3_logging_rows=0
s3_bucket_checks=0
s3_bucket_skipped=0

while IFS= read -r profile_name; do
  profile_bucket_checks=0
  [[ -n "${profile_name}" ]] || continue
  profile_selected "${profile_name}" || continue
  selected_count=$((selected_count + 1))
  log "Discovering audit-log sources for profile ${profile_name}..."

  account_id="$(aws_retry_capture aws sts get-caller-identity --profile "${profile_name}" --query 'Account' --output text || true)"
  arn="$(aws_retry_capture aws sts get-caller-identity --profile "${profile_name}" --query 'Arn' --output text || true)"
  [[ -n "${account_id}" && "${account_id}" != "None" ]] || {
    log "WARN: Skipping ${profile_name}; unable to resolve caller identity."
    continue
  }
  usable_profiles=$((usable_profiles + 1))
  printf '%s\t%s\t%s\t%s\n' "${profile_name}" "${account_id}" "$(safe_text "${arn}")" "${PROFILE_SELECTOR}" >> "${PROFILE_TSV}"

  cloudtrail_output="$(
    aws_retry_capture aws cloudtrail describe-trails \
      --profile "${profile_name}" \
      --include-shadow-trails \
      --query 'trailList[?S3BucketName!=null].[Name,S3BucketName,S3KeyPrefix,HomeRegion,IsMultiRegionTrail,IsOrganizationTrail]' \
      --output text || true
  )"
  if [[ -n "${cloudtrail_output}" ]]; then
    append_cloudtrail_rows "${profile_name}" "${account_id}" "${cloudtrail_output}"
    cloudtrail_rows=$((cloudtrail_rows + $(printf '%s\n' "${cloudtrail_output}" | sed '/^[[:space:]]*$/d' | wc -l)))
  fi

  bucket_list="$(aws_retry_capture aws s3api list-buckets --profile "${profile_name}" --query 'Buckets[].Name' --output text || true)"
  [[ -n "${bucket_list}" ]] || continue

  for bucket_name in ${bucket_list}; do
    if (( DISCOVERY_S3_BUCKET_LIMIT_PER_PROFILE > 0 && profile_bucket_checks >= DISCOVERY_S3_BUCKET_LIMIT_PER_PROFILE )); then
      s3_bucket_skipped=$((s3_bucket_skipped + 1))
      continue
    fi

    s3_bucket_checks=$((s3_bucket_checks + 1))
    profile_bucket_checks=$((profile_bucket_checks + 1))
    bucket_region="$(aws_retry_capture aws s3api get-bucket-location --profile "${profile_name}" --bucket "${bucket_name}" --query 'LocationConstraint' --output text || true)"
    if [[ "${bucket_region}" == "None" ]]; then
      bucket_region="us-east-1"
    fi

    target_bucket="$(aws_retry_capture aws s3api get-bucket-logging --profile "${profile_name}" --bucket "${bucket_name}" --query 'LoggingEnabled.TargetBucket' --output text || true)"
    target_prefix="$(aws_retry_capture aws s3api get-bucket-logging --profile "${profile_name}" --bucket "${bucket_name}" --query 'LoggingEnabled.TargetPrefix' --output text || true)"

    [[ -n "${target_bucket}" && "${target_bucket}" != "None" ]] || continue
    append_s3_logging_row "${profile_name}" "${account_id}" "${bucket_name}" "${bucket_region}" "${target_bucket}" "${target_prefix}"
    s3_logging_rows=$((s3_logging_rows + 1))
  done
done < <(aws configure list-profiles)

{
  printf 'Profiles selected: %s\n' "${selected_count}"
  printf 'Profiles usable: %s\n' "${usable_profiles}"
  printf 'CloudTrail rows: %s\n' "${cloudtrail_rows}"
  printf 'S3 access logging rows: %s\n' "${s3_logging_rows}"
  printf 'S3 buckets checked: %s\n' "${s3_bucket_checks}"
  printf 'S3 buckets skipped by limit: %s\n' "${s3_bucket_skipped}"
  printf 'S3 bucket limit per profile: %s\n' "${DISCOVERY_S3_BUCKET_LIMIT_PER_PROFILE}"
  printf 'Run directory: %s\n' "${RUN_DIR}"
} > "${SUMMARY_FILE}"

if [[ "${usable_profiles}" -eq 0 ]]; then
  log "ERROR: No usable AWS profiles were authenticated for selector ${PROFILE_SELECTOR}."
  exit 1
fi

update_latest_link

printf '%s\n' "${RUN_DIR}"
