#!/bin/bash

# Machine Status Monitoring System Deployment Script

# Exit on any error
set -e

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Function to check and install dependencies
install_dependencies() {
    echo "Installing system dependencies..."
    apt-get update
    apt-get install -y \
        python3 \
        python3-pip \
        postgresql \
        postgresql-contrib \
        python3-dev \
        libpq-dev

    # Install Python dependencies
    pip3 install \
        flask \
        flask-sqlalchemy \
        psutil \
        netifaces \
        requests \
        sqlalchemy \
        psycopg2-binary
}

# Function to setup PostgreSQL database
setup_database() {
    echo "Setting up PostgreSQL database..."
    
    # Prompt for database configuration
    read -p "Enter database name (default: machine_status_db): " DB_NAME
    DB_NAME=${DB_NAME:-machine_status_db}
    
    read -p "Enter database user (default: machine_status_user): " DB_USER
    DB_USER=${DB_USER:-machine_status_user}
    
    # Generate a secure random password
    DB_PASS=$(openssl rand -base64 12)

    # Create PostgreSQL user and database
    sudo -u postgres psql <<POSTGRESQL_SCRIPT
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
CREATE DATABASE ${DB_NAME};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
POSTGRESQL_SCRIPT

    # Store database credentials securely
    mkdir -p /etc/machine-status
    chmod 700 /etc/machine-status
    echo "DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost/${DB_NAME}" > /etc/machine-status/db.env
    chmod 600 /etc/machine-status/db.env

    echo "Database setup complete. Credentials stored in /etc/machine-status/db.env"
}

# Function to deploy machine status publisher
deploy_machine_status_publisher() {
    echo "Deploying Machine Status Publisher..."
    
    # Copy publisher script
    cp machine-status-publisher.py /usr/local/bin/machine-status-publisher.py
    chmod +x /usr/local/bin/machine-status-publisher.py

    # Copy systemd service file
    cp machine-status-publisher.service /etc/systemd/system/machine-status-publisher.service

    # Reload systemd, enable and start service
    systemctl daemon-reload
    systemctl enable machine-status-publisher
    systemctl start machine-status-publisher

    echo "Machine Status Publisher deployed and started"
}

# Function to deploy machine status server
deploy_machine_status_server() {
    echo "Deploying Machine Status Server..."
    
    # Copy server script
    cp machine-status-server.py /usr/local/bin/machine-status-server.py
    chmod +x /usr/local/bin/machine-status-server.py

    # Create systemd service for server
    cat > /etc/systemd/system/machine-status-server.service <<EOL
[Unit]
Description=Machine Status Server
After=network.target postgresql.service

[Service]
Type=simple
User=root
EnvironmentFile=/etc/machine-status/db.env
ExecStart=/usr/bin/python3 /usr/local/bin/machine-status-server.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd, enable and start service
    systemctl daemon-reload
    systemctl enable machine-status-server
    systemctl start machine-status-server

    echo "Machine Status Server deployed and started"
}

# Main deployment function
main() {
    echo "Starting Machine Status Monitoring System Deployment"
    
    # Install dependencies
    install_dependencies
    
    # Setup database
    setup_database
    
    # Deploy publisher
    deploy_machine_status_publisher
    
    # Deploy server
    deploy_machine_status_server

    echo "Deployment complete!"
    echo "Please configure your firewall to allow incoming connections on port 5000"
    echo "and update the SERVER_URL in machine-status-publisher.py with your server's address"
}

# Run the main deployment function
main
