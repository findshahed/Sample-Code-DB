# airflow_dags/operators/snowflake_operator.py
"""
Custom Snowflake operators for Airflow
"""
from typing import Optional, Dict, List, Any
from airflow.models import BaseOperator
from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook
from airflow.utils.decorators import apply_defaults


class SnowflakeStoredProcedureOperator(BaseOperator):
    """
    Execute a Snowflake stored procedure
    """
    
    template_fields = ('procedure_name', 'parameters', 'database', 'schema')
    
    @apply_defaults
    def __init__(
        self,
        procedure_name: str,
        database: Optional[str] = None,
        schema: Optional[str] = None,
        parameters: Optional[List[Any]] = None,
        snowflake_conn_id: str = 'snowflake_default',
        *args, **kwargs
    ):
        super().__init__(*args, **kwargs)
        self.procedure_name = procedure_name
        self.database = database
        self.schema = schema
        self.parameters = parameters or []
        self.snowflake_conn_id = snowflake_conn_id
    
    def execute(self, context):
        hook = SnowflakeHook(snowflake_conn_id=self.snowflake_conn_id)
        
        # Set database and schema if provided
        if self.database:
            hook.run(f"USE DATABASE {self.database};")
        if self.schema:
            hook.run(f"USE SCHEMA {self.schema};")
        
        # Build procedure call
        params_str = ', '.join([self._format_param(p) for p in self.parameters])
        sql = f"CALL {self.procedure_name}({params_str});"
        
        self.log.info(f"Executing: {sql}")
        result = hook.get_first(sql)
        
        if result:
            self.log.info(f"Procedure result: {result}")
        
        return result
    
    def _format_param(self, param: Any) -> str:
        """Format parameter for SQL"""
        if isinstance(param, str):
            return f"'{param}'"
        elif param is None:
            return 'NULL'
        else:
            return str(param)


class SnowflakeFileFormatOperator(BaseOperator):
    """
    Create or replace a Snowflake file format
    """
    
    @apply_defaults
    def __init__(
        self,
        file_format_name: str,
        file_format_type: str = 'JSON',
        database: Optional[str] = None,
        schema: Optional[str] = None,
        options: Optional[Dict[str, Any]] = None,
        snowflake_conn_id: str = 'snowflake_default',
        *args, **kwargs
    ):
        super().__init__(*args, **kwargs)
        self.file_format_name = file_format_name
        self.file_format_type = file_format_type
        self.database = database
        self.schema = schema
        self.options = options or {}
        self.snowflake_conn_id = snowflake_conn_id
    
    def execute(self, context):
        hook = SnowflakeHook(snowflake_conn_id=self.snowflake_conn_id)
        
        # Set database and schema if provided
        if self.database:
            hook.run(f"USE DATABASE {self.database};")
        if self.schema:
            hook.run(f"USE SCHEMA {self.schema};")
        
        # Build options string
        options_str = []
        for key, value in self.options.items():
            if isinstance(value, str):
                options_str.append(f"{key} = '{value}'")
            elif value is True:
                options_str.append(f"{key} = TRUE")
            elif value is False:
                options_str.append(f"{key} = FALSE")
            else:
                options_str.append(f"{key} = {value}")
        
        options_clause = '\n    '.join(options_str)
        
        # Create file format
        sql = f"""
        CREATE OR REPLACE FILE FORMAT {self.file_format_name}
        TYPE = {self.file_format_type}
        {options_clause};
        """
        
        self.log.info(f"Creating file format: {self.file_format_name}")
        hook.run(sql)
        
        return f"File format {self.file_format_name} created successfully"


class SnowflakeStageOperator(BaseOperator):
    """
    Create or replace a Snowflake stage
    """
    
    @apply_defaults
    def __init__(
        self,
        stage_name: str,
        url: str,
        storage_integration: Optional[str] = None,
        file_format: Optional[str] = None,
        database: Optional[str] = None,
        schema: Optional[str] = None,
        snowflake_conn_id: str = 'snowflake_default',
        *args, **kwargs
    ):
        super().__init__(*args, **kwargs)
        self.stage_name = stage_name
        self.url = url
        self.storage_integration = storage_integration
        self.file_format = file_format
        self.database = database
        self.schema = schema
        self.snowflake_conn_id = snowflake_conn_id
    
    def execute(self, context):
        hook = SnowflakeHook(snowflake_conn_id=self.snowflake_conn_id)
        
        # Set database and schema if provided
        if self.database:
            hook.run(f"USE DATABASE {self.database};")
        if self.schema:
            hook.run(f"USE SCHEMA {self.schema};")
        
        # Build stage creation SQL
        sql_parts = [f"CREATE OR REPLACE STAGE {self.stage_name}"]
        sql_parts.append(f"URL = '{self.url}'")
        
        if self.storage_integration:
            sql_parts.append(f"STORAGE_INTEGRATION = {self.storage_integration}")
        
        if self.file_format:
            sql_parts.append(f"FILE_FORMAT = {self.file_format}")
        
        sql = '\n'.join(sql_parts) + ';'
        
        self.log.info(f"Creating stage: {self.stage_name}")
        hook.run(sql)
        
        return f"Stage {self.stage_name} created successfully"
