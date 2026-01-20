-- Optimize clustering for common query patterns
-- Following script updates clustering keys for table valid trades
-- It also have a query to monitor cluster efficiency

ALTER TABLE TRADE_DB.PROCESSED.VALID_TRADES 
CLUSTER BY (
    DATE(TRADE_DATE),
    COUNTERPARTY_ID,
    STATUS
);

-- Monitor clustering efficiency
SELECT 
    TABLE_NAME,
    AVG_DEPTH,
    CLUSTERING_KEY,
    ROW_COUNT
FROM INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_SCHEMA = 'PROCESSED'
ORDER BY AVG_DEPTH DESC;
