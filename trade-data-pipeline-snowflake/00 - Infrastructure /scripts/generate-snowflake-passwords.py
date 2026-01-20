# infrastructure/scripts/generate-snowflake-passwords.py
# Python script to generate strong 16-character passwords
# Script generates passwords for the users: trade_loader, trade_analyst and trade_admin and stores in Googles secrets manager
#!/usr/bin/env python3
"""
Generate secure passwords for Snowflake users and store them in Google Secret Manager
"""
import json
import random
import string
import sys
from google.cloud import secretmanager

def generate_password(length=16):
    """Generate a secure random password"""
    chars = string.ascii_letters + string.digits + "!#$%&*()-_=+[]{}<>:?"
    return ''.join(random.choice(chars) for _ in range(length))

def store_secret(project_id, secret_id, secret_data):
    """Store secret in Google Secret Manager"""
    client = secretmanager.SecretManagerServiceClient()
    
    # Create secret if it doesn't exist
    try:
        secret = client.create_secret(
            request={
                "parent": f"projects/{project_id}",
                "secret_id": secret_id,
                "secret": {
                    "replication": {"automatic": {}}
                }
            }
        )
    except Exception as e:
        if "already exists" not in str(e):
            raise
    
    # Add secret version
    parent = f"projects/{project_id}/secrets/{secret_id}"
    response = client.add_secret_version(
        request={
            "parent": parent,
            "payload": {
                "data": secret_data.encode("UTF-8")
            }
        }
    )
    
    print(f"Stored secret: {secret_id}")
    return response

def main():
    if len(sys.argv) != 3:
        print("Usage: python generate-snowflake-passwords.py <project_id> <environment>")
        sys.exit(1)
    
    project_id = sys.argv[1]
    environment = sys.argv[2]
    
    # Generate passwords for each user
    users = {
        "trade_loader": generate_password(),
        "trade_analyst": generate_password(),
        "trade_admin": generate_password()
    }
    
    # Store each password as a separate secret
    for user, password in users.items():
        secret_id = f"snowflake-{user}-password-{environment}"
        store_secret(project_id, secret_id, password)
    
    # Store all passwords together for Terraform
    all_passwords = {
        "users": users,
        "environment": environment,
        "generated_at": "2024-01-01T00:00:00Z"
    }
    
    store_secret(
        project_id,
        f"snowflake-all-passwords-{environment}",
        json.dumps(all_passwords, indent=2)
    )
    
    print("Passwords generated and stored successfully!")
    print("\nUser passwords:")
    for user, password in users.items():
        print(f"{user}: {password}")

if __name__ == "__main__":
    main()
