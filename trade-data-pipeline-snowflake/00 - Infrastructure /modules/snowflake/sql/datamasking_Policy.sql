-- Data masking policy and application
-- Following actions are performed by this script
-- Create masking policy for sensitive data
-- Apply data masking policy on column VALID_TRADES.COUNTERPARTY_ID
-- The script also creates a regional data access policy based on user roles
--
CREATE OR REPLACE MASKING POLICY trade_data_mask AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('TRADE_ADMIN', 'ACCOUNTADMIN') THEN val
        WHEN CURRENT_ROLE() = 'TRADE_ANALYST' THEN 
            CASE 
                WHEN IS_ACCOUNT_ADMIN(CURRENT_USER()) THEN val
                ELSE REGEXP_REPLACE(val, '(\\w{3})\\w+(\\w{3})', '\\1***\\2')
            END
        ELSE '********'
    END;

-- Apply masking to sensitive columns
ALTER TABLE TRADE_DB.PROCESSED.VALID_TRADES 
MODIFY COLUMN COUNTERPARTY_ID 
SET MASKING POLICY trade_data_mask;

-- Create row access policy
CREATE OR REPLACE ROW ACCESS POLICY trade_region_policy AS (region STRING) RETURNS BOOLEAN ->
    CASE
        WHEN CURRENT_ROLE() = 'TRADE_ADMIN' THEN TRUE
        WHEN CURRENT_ROLE() = 'TRADE_ANALYST' AND region = 'EMEA' THEN TRUE
        ELSE FALSE
    END;

ALTER TABLE TRADE_DB.PROCESSED.VALID_TRADES 
ADD ROW ACCESS POLICY trade_region_policy ON (REGION);
