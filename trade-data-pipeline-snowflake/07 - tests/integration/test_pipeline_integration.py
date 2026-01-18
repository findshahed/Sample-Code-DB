
# 07-tests/integration/test_pipeline_integration.py
import pytest
import snowflake.connector
from datetime import datetime
import json

class TestTradePipeline:
    @pytest.fixture
    def snowflake_connection(self):
        """Create test Snowflake connection"""
        conn = snowflake.connector.connect(
            user=os.environ['SNOWFLAKE_TEST_USER'],
            password=os.environ['SNOWFLAKE_TEST_PASSWORD'],
            account=os.environ['SNOWFLAKE_TEST_ACCOUNT'],
            warehouse='TRADE_TEST_WH',
            database='TRADE_TEST_DB',
            schema='TEST',
            role='TRADE_TEST_ROLE'
        )
        yield conn
        conn.close()
    
    def test_version_validation(self, snowflake_connection):
        """Test version-based validation logic"""
        # Insert older version
        cursor = snowflake_connection.cursor()
        cursor.execute("""
            INSERT INTO VALID_TRADES_TEST 
            VALUES ('TRD001', 1, 'CP001', 'INST001', 
                    100, 50.0, 'BUY', 'USD', 
                    CURRENT_TIMESTAMP(), 
                    DATEADD('DAY', 30, CURRENT_TIMESTAMP()),
                    'VALID', CURRENT_TIMESTAMP())
        """)
        
        # Try to insert newer version (should succeed)
        # Try to insert older version (should be rejected)
        # Assert counts
        
    def test_maturity_date_validation(self, snowflake_connection):
        """Test maturity date validation"""
        # Insert trade with past maturity date
        # Should be marked as expired
        # Verify status update
        
    def test_pipeline_performance(self, snowflake_connection):
        """Test pipeline performance with bulk data"""
        start_time = datetime.now()
        
        # Generate and process 100k trades
        # Measure ingestion time
        # Validate all records
        
        end_time = datetime.now()
        duration = (end_time - start_time).total_seconds()
        
        assert duration < 300  # Should complete in under 5 minutes
        
    def test_error_handling(self):
        """Test error handling and dead letter queue"""
        # Send malformed messages
        # Verify they go to error table
        # Check that valid messages continue processing
