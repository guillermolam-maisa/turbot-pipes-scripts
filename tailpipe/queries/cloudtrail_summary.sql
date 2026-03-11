select
  count(*) as event_count,
  min(event_time) as first_event_at,
  max(event_time) as last_event_at
from aws_cloudtrail_log;
