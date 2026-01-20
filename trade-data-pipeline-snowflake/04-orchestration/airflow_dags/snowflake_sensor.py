# airflow_dags/sensors/snowflake_sensor.py
"""
Custom Snowflake sensors for Airflow
"""
from datetime import datetime, timedelta
from typing import Optional

from airflow.sensors.base import BaseSensorOperator
from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook
from airflow.utils.decorators import apply_defaults


class SnowflakeTableSensor(BaseSensorOperator):
    """
    Sensor that waits for data in a Snowflake table
    """
    
    template_fields = ('table_name', 'target_date')
    
    @apply_defaults
    def __init__(
        self,
        table_name: str,
        target_date: Optional[str] = None,
        date_column: str = 'PROCESSED_AT',
        min_count: int = 1,
        snowflake_conn_id: str = 'snowflake_default',
        *args, **kwargs
    ):
        super().__init__(*args, **kwargs)
        self.table_name = table_name
        self.target_date = target_date
        self.date_column = date_column
        self.min_count = min_count
        self.snowflake_conn_id = snowflake_conn_id
    
    def poke(self, context):
        hook = SnowflakeHook(snowflake_conn_id=self.snowflake_conn_id)
        
        if self.target_date:
            # Check for data on specific date
            query = f"""
            SELECT COUNT(*) 
            FROM {self.table_name}
            WHERE DATE({self.date_column}) = '{self.target_date}'
            """
        else:
            # Check for any recent data (last hour)
            query = f"""
            SELECT COUNT(*) 
            FROM {self.table_name}
            WHERE {self.date_column} >= DATEADD('HOUR', -1, CURRENT_TIMESTAMP())
            """
        
        self.log.info(f"Checking table: {self.table_name}")
        result = hook.get_first(query)
        
        if result and result[0] >= self.min_count:
            self.log.info(f"Found {result[0]} records in {self.table_name}")
            return True
        
        return False


class SnowflakeQuerySensor(BaseSensorOperator):
    """
    Sensor that waits for a query to return a specific result
    """
    
    template_fields = ('sql', 'expected_result')
    
    @apply_defaults
    def __init__(
        self,
        sql: str,
        expected_result: any = None,
        snowflake_conn_id: str = 'snowflake_default',
        *args, **kwargs
    ):
        super().__init__(*args, **kwargs)
        self.sql = sql
        self.expected_result = expected_result
        self.snowflake_conn_id = snowflake_conn_id
    
    def poke(self, context):
        hook = SnowflakeHook(snowflake_conn_id=self.snowflake_conn_id)
        
        self.log.info(f"Executing query: {self.sql}")
        result = hook.get_first(self.sql)
        
        if self.expected_result is not None:
            if result and result[0] == self.expected_result:
                return True
        else:
            # Just check if query returns any result
            if result and result[0] > 0:
                return True
        
        return False


class SnowflakePipeSensor(BaseSensorOperator):
    """
    Sensor that waits for Snowpipe to finish processing
    """
    
    @apply_defaults
    def __init__(
        self,
        pipe_name: str,
        max_lag_minutes: int = 30,
        snowflake_conn_id: str = 'snowflake_default',
        *args, **kwargs
    ):
        super().__init__(*args, **kwargs)
        self.pipe_name = pipe_name
        self.max_lag_minutes = max_lag_minutes
        self.snowflake_conn_id = snowflake_conn_id
    
    def poke(self, context):
        hook = SnowflakeHook(snowflake_conn_id=self.snowflake_conn_id)
        
        query = f"""
        SELECT 
            DATEDIFF('MINUTE', LAST_INGESTED, CURRENT_TIMESTAMP()) as lag_minutes,
            PENDING_FILE_COUNT
        FROM INFORMATION_SCHEMA.PIPES
        WHERE PIPE_NAME = '{self.pipe_name}'
        """
        
        result = hook.get_first(query)
        
        if result:
            lag_minutes, pending_files = result
            
            self.log.info(f"Pipe {self.pipe_name}: Lag={lag_minutes}min, Pending={pending_files} files")
            
            if lag_minutes <= self.max_lag_minutes and pending_files == 0:
                return True
        
        return False
