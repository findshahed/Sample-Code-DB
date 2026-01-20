# 03-snowflake-integration/snowpark/udfs.py
# This python script creates some user defined functions to utilized within the project
# some of the udfs created after create session are
# 1. trade validation
# 2. calculate trade value
# 3 Bulk trade validation stored procedure
#

from snowflake.snowpark import Session
from snowflake.snowpark.functions import udf, col
from snowflake.snowpark.types import StringType, IntegerType, TimestampType
import json
from datetime import datetime

# Initialize session
def create_session():
    connection_parameters = {
        "account": os.environ["SNOWFLAKE_ACCOUNT"],
        "user": os.environ["SNOWFLAKE_USER"],
        "password": os.environ["SNOWFLAKE_PASSWORD"],
        "warehouse": "TRADE_TRANSFORM_WH",
        "database": "TRADE_DB",
        "schema": "PROCESSED",
        "role": "TRADE_ADMIN"
    }
    return Session.builder.configs(connection_parameters).create()

# UDF for trade validation
@udf(name="validate_trade_udf", 
     return_type=StringType(),
     input_types=[StringType(), TimestampType()],
     session=session)
def validate_trade(trade_json, existing_trade_date):
    """Validate trade business rules"""
    try:
        trade = json.loads(trade_json)
        
        # Check maturity date
        maturity_date = datetime.fromisoformat(trade['maturity_date'])
        if maturity_date < datetime.utcnow():
            return 'EXPIRED'
        
        # Check if newer version
        if existing_trade_date:
            trade_date = datetime.fromisoformat(trade['trade_date'])
            if trade_date <= existing_trade_date:
                return 'OLDER_VERSION'
        
        return 'VALID'
    except Exception as e:
        return f'ERROR: {str(e)}'

# UDF for calculating trade value
@udf(name="calculate_trade_value",
     return_type=DecimalType(20, 6),
     input_types=[IntegerType(), DecimalType(20, 6), StringType()],
     session=session)
def calculate_trade_value(quantity, price, currency):
    """Calculate trade value with currency adjustment"""
    currency_rates = {
        'USD': 1.0,
        'EUR': 1.1,
        'GBP': 1.3,
        'JPY': 0.009
    }
    
    rate = currency_rates.get(currency, 1.0)
    return quantity * price * rate

# Stored Procedure for bulk validation
def create_validation_procedure(session):
    """Create stored procedure for batch validation"""
    
    @udf(name="bulk_validate_trades", 
         is_permanent=True,
         stage_location="@TRADE_DB.PROCESSED.udf_stage",
         session=session)
    def bulk_validate_trades(trades_array):
        """Validate multiple trades at once"""
        results = []
        for trade_json in trades_array:
            trade = json.loads(trade_json)
            # Add validation logic
            results.append({
                'trade_id': trade['trade_id'],
                'is_valid': True,
                'reason': 'VALID'
            })
        return json.dumps(results)
    
    return bulk_validate_trades
