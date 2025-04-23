#!/bin/bash

# Machine Status Monitoring System Installer
# Usage: sudo ./install_machine_status.sh [server|client]

set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[INSTALLER]${NC} $1"
}

# Error handling function
error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Proxy configuration
PROXY_HOST="${PROXY_HOST:-proxy.iil.intel.com}"
PROXY_PORT="${PROXY_PORT:-912}"

# Configuration variables
MQTT_BROKER_ADDRESS="${MQTT_BROKER_ADDRESS:-localhost}"
MQTT_BROKER_PORT="${MQTT_BROKER_PORT:-1883}"

# Previous functions (detect_distribution, configure_system_proxy, 
# install_common_dependencies, install_python_dependencies, 
# install_mqtt_broker, configure_mqtt_broker, install_machine_status_publisher) 
# remain the same as in the previous artifact...

# Install server components
install_server() {
    log "Setting up Machine Status Server..."
    
    # Configure system proxy
    configure_system_proxy
    
    # Install common dependencies
    install_common_dependencies
    
    # Install Python dependencies
    install_python_dependencies
    
    # Install PostgreSQL
    log "Installing PostgreSQL..."
    sudo apt-get update
    sudo apt-get install -y postgresql postgresql-contrib
    
    # Configure PostgreSQL
    configure_postgresql
    
    # Install and configure MQTT Broker
    install_mqtt_broker
    configure_mqtt_broker
    
    # Install Machine Status Subscriber
    install_machine_status_subscriber
    
    log "Machine Status Server setup complete!"
}

# Configure PostgreSQL
configure_postgresql() {
    log "Configuring PostgreSQL..."
    
    # Generate random database credentials
    DB_NAME="machine_status_db"
    DB_USER="machine_status_user"
    DB_PASS=$(openssl rand -base64 16)
    
    # Create database and user
    sudo -u postgres psql <<POSTGRESQL_SCRIPT
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
CREATE DATABASE ${DB_NAME};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
POSTGRESQL_SCRIPT
    
    # Store credentials securely
    sudo mkdir -p /etc/machine-status
    sudo tee /etc/machine-status/db.env > /dev/null <<EOL
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost/${DB_NAME}
EOL
    sudo chmod 600 /etc/machine-status/db.env
    
    log "PostgreSQL configured with new database and user"
}

# Install Machine Status Subscriber
install_machine_status_subscriber() {
    log "Installing Machine Status Subscriber..."
    
    # Create installation directory
    sudo mkdir -p /opt/machine-status/subscriber
    
    # Copy subscriber script
    sudo tee /opt/machine-status/subscriber/machine_status_subscriber.py > /dev/null <<'SUBSCRIBER_SCRIPT'
#!/opt/machine-status/venv/bin/python3

import os
import json
import logging
from typing import Dict, Any

import paho.mqtt.client as mqtt
import sqlalchemy as sa
from sqlalchemy.orm import sessionmaker
from sqlalchemy.ext.declarative import declarative_base

# Configure logging
logging.basicConfig(
    filename='/var/log/machine-status-subscriber.log', 
    level=logging.INFO, 
    format='%(asctime)s - %(levelname)s - %(message)s'
)

# SQLAlchemy Base and Session setup
Base = declarative_base()

class MachineStatus(Base):
    """
    Database model to store machine status information
    """
    __tablename__ = 'machine_statuses'

    id = sa.Column(sa.Integer, primary_key=True)
    machine_id = sa.Column(sa.String(255), nullable=False, index=True)
    hostname = sa.Column(sa.String(255), nullable=False)
    ip_address = sa.Column(sa.String(100))
    cpu_model = sa.Column(sa.String(255))
    cpu_cores = sa.Column(sa.Integer)
    cpu_usage = sa.Column(sa.Float)
    memory_total = sa.Column(sa.String(50))
    memory_available = sa.Column(sa.String(50))
    memory_usage = sa.Column(sa.Float)
    storage_total = sa.Column(sa.String(50))
    storage_free = sa.Column(sa.String(50))
    storage_usage = sa.Column(sa.Float)
    timestamp = sa.Column(sa.DateTime, server_default=sa.func.now())

class MachineStatusSubscriber:
    def __init__(
        self, 
        mqtt_broker_address: str = 'localhost', 
        mqtt_broker_port: int = 1883, 
        mqtt_username: str = 'machine_status', 
        mqtt_password: str = None,
        database_url: str = None
    ):
        """
        Initialize MQTT Machine Status Subscriber
        """
        # MQTT Client setup
        self.client = mqtt.Client()
        self.broker_address = mqtt_broker_address
        self.broker_port = mqtt_broker_port
        
        # Database setup
        if not database_url:
            database_url = os.getenv(
                'DATABASE_URL', 
                'postgresql://username:password@localhost/machine_status_db'
            )
        self.engine = sa.create_engine(database_url)
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine)

        # Set up MQTT authentication
        if mqtt_username and mqtt_password:
            self.client.username_pw_set(mqtt_username, mqtt_password)
        
        # Set up client callbacks
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect

    def _on_connect(self, client, userdata, flags, rc):
        """
        MQTT connection callback
        """
        if rc == 0:
            logging.info("Connected to MQTT Broker successfully")
            # Subscribe to machine status topic
            client.subscribe("machine_status/#")
        else:
            logging.error(f"Failed to connect to MQTT Broker. Return code: {rc}")

    def _on_message(self, client, userdata, msg):
        """
        Callback for when a message is received from the server.
        """
        try:
            # Decode payload
            payload = msg.payload.decode('utf-8')
            machine_info = json.loads(payload)
            
            # Store in database
            self._store_machine_status(machine_info)
            
            logging.info(f"Received status for machine {machine_info.get('machine_id')}")
        
        except json.JSONDecodeError:
            logging.error(f"Failed to decode JSON from topic {msg.topic}")
        except Exception as e:
            logging.error(f"Error processing message: {e}")

    def _store_machine_status(self, machine_info: Dict[str, Any]):
        """
        Store machine status in database
        """
        try:
            # Create database session
            session = self.Session()
            
            # Create MachineStatus record
            status_record = MachineStatus(
                machine_id=machine_info.get('machine_id', 'Unknown'),
                hostname=machine_info.get('hostname', 'Unknown'),
                ip_address=machine_info.get('ip_address', ''),
                cpu_model=machine_info.get('cpu', {}).get('model', 'Unknown'),
                cpu_cores=machine_info.get('cpu', {}).get('cores', 0),
                cpu_usage=machine_info.get('cpu', {}).get('usage_percent', 0),
                memory_total=machine_info.get('memory', {}).get('total', 'Unknown'),
                memory_available=machine_info.get('memory', {}).get('available', 'Unknown'),
                memory_usage=machine_info.get('memory', {}).get('usage_percent', 0),
                storage_total=machine_info.get('storage', {}).get('total', 'Unknown'),
                storage_free=machine_info.get('storage', {}).get('free', 'Unknown'),
                storage_usage=machine_info.get('storage', {}).get('usage_percent', 0)
            )
            
            # Add and commit record
            session.add(status_record)
            session.commit()
        
        except Exception as e:
            session.rollback()
            logging.error(f"Error storing machine status: {e}")
        finally:
            session.close()

    def _on_disconnect(self, client, userdata, rc):
        """
        MQTT disconnection callback
        """
        logging.warning(f"Disconnected from MQTT Broker. Return code: {rc}")
        # Attempt to reconnect
        try:
            client.reconnect()
        except Exception as e:
            logging.error(f"Reconnection failed: {e}")

    def run(self):
        """
        Run the MQTT Machine Status Subscriber
        """
        try:
            # Connect to MQTT Broker
            self.client.connect(self.broker_address, self.broker_port, 60)
            
            # Start MQTT loop
            logging.info("Starting MQTT Machine Status Subscriber")
            self.client.loop_forever()
        
        except Exception as e:
            logging.error(f"Fatal error in subscriber: {e}")
        finally:
            # Ensure clean disconnection
            self.client.disconnect()

def main():
    # Load configuration from environment files
    mqtt_config = {}
    db_config = {}
    
    # Load MQTT configuration
    mqtt_config_file = '/etc/machine-status/mqtt.env'
    if os.path.exists(mqtt_config_file):
        with open(mqtt_config_file, 'r') as f:
            for line in f:
                key, value = line.strip().split('=', 1)
                mqtt_config[key] = value
    
    # Load Database configuration
    db_config_file = '/etc/machine-status/db.env'
    if os.path.exists(db_config_file):
        with open(db_config_file, 'r') as f:
            for line in f:
                key, value = line.strip().split('=', 1)
                db_config[key] = value
    
    # Create and run subscriber
    subscriber = MachineStatusSubscriber(
        mqtt_broker_address=mqtt_config.get('MQTT_BROKER_ADDRESS', 'localhost'),
        mqtt_broker_port=int(mqtt_config.get('MQTT_BROKER_PORT', 1883)),
        mqtt_username=mqtt_config.get('MQTT_USERNAME', 'machine_status'),
        mqtt_password=mqtt_config.get('MQTT_PASSWORD'),
        database_url=db_config.get('DATABASE_URL')
    )
    
    # Run the subscriber
    subscriber.run()

if __name__ == "__main__":
    main()
SUBSCRIBER_SCRIPT

    # Set correct permissions
    sudo chmod +x /opt/machine-status/subscriber/machine_status_subscriber.py
    
    # Create systemd service for subscriber
    sudo tee /etc/systemd/system/machine-status-subscriber.service > /dev/null <<EOL
[Unit]
Description=Machine Status MQTT Subscriber
After=network.target mosquitto.service postgresql.service

[Service]
Type=simple
User=root
EnvironmentFile=/etc/machine-status/mqtt.env
EnvironmentFile=/etc/machine-status/db.env
ExecStart=/opt/machine-status/venv/bin/python3 /opt/machine-status/subscriber/machine_status_subscriber.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd, enable and start service
    sudo systemctl daemon-reload
    sudo systemctl enable machine-status-subscriber
    sudo systemctl start machine-status-subscriber
}

# Main installation function
main() {
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
       error "This script must be run as root. Use sudo."
    fi

    # Detect distribution
    detect_distribution

    # Parse command-line arguments
    case "$1" in 
        server)
            install_server
            ;;
        client)
            install_client
            ;;
        *)
            echo "Usage: $0 {server|client}"
            echo "  server: Install machine status monitoring server"
            echo "  client: Install machine status monitoring client"
            exit 1
            ;;
    esac
}

# Run main function with command-line arguments
main "$@"