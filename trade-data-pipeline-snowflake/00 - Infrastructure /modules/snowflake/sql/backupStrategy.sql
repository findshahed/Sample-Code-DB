-- Create failover group
-- Following script sets up failover mechanism for database restore in a point of time
-- Currently setup 24-hours ago

CREATE FAILOVER GROUP TRADE_FAILOVER_GROUP
  OBJECT_TYPES = ACCOUNT, DATABASES, SHARES
  ALLOWED_DATABASES = (TRADE_DB)
  ALLOWED_ACCOUNTS = (secondary_account)
  REPLICATION_SCHEDULE = '10 MINUTE';

-- Enable time travel for all tables
ALTER DATABASE TRADE_DB 
SET DATA_RETENTION_TIME_IN_DAYS = 90;

-- Create periodic clones for point-in-time recovery
CREATE OR REPLACE DATABASE TRADE_DB_DEV_CLONE 
CLONE TRADE_DB 
AT (OFFSET => -60*60*24); -- 24 hours ago
