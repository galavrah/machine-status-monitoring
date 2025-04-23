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

# Detect Linux distribution
detect_distribution() {
    # Check if /etc/os-release exists (standard for modern Linux distributions)
    if [ -f /etc/os-release ]; then
        # Source the file to get distribution information
        . /etc/os-release
        
        # Set distribution variables
        DISTRO=$ID          # e.g., ubuntu, fedora, debian
        DISTRO_VERSION=$VERSION_ID  # e.g., 20.04, 22.04
        
        log "Detected Distribution: ${DISTRO} ${DISTRO_VERSION}"
    else
        # Fallback for older systems
        if [ -f /etc/lsb-release ]; then
            . /etc/lsb-release
            DISTRO=$DISTRIB_ID
            DISTRO_VERSION=$DISTRIB_RELEASE
        elif [ -f /etc/redhat-release ]; then
            DISTRO=$(cat /etc/redhat-release | cut -d' ' -f1)
            DISTRO_VERSION=$(cat /etc/redhat-release | cut -d' ' -f3)
        else
            error "Unable to detect Linux distribution"
            return 1
        fi
        
        log "Detected Distribution: ${DISTRO} ${DISTRO_VERSION}"
    fi
    
    # Export variables for use in other functions
    export DISTRO
    export DISTRO_VERSION
}

# Configure system proxy
configure_system_proxy() {
    log "Configuring system proxy..."
    
    # Set up environment variables
    export http_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
    export https_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
    export no_proxy="localhost,127.0.0.1"
    
    # Configure apt proxy if available
    if command -v apt-get >/dev/null 2>&1; then
        sudo mkdir -p /etc/apt/apt.conf.d/
        sudo tee /etc/apt/apt.conf.d/80proxy > /dev/null <<EOL
Acquire::http::Proxy "http://${PROXY_HOST}:${PROXY_PORT}";
Acquire::https::Proxy "http://${PROXY_HOST}:${PROXY_PORT}";
EOL
    fi
    
    # Configure pip proxy
    sudo mkdir -p ~/.pip
    sudo tee ~/.pip/pip.conf > /dev/null <<EOL
[global]
proxy = http://${PROXY_HOST}:${PROXY_PORT}
EOL

    log "System proxy configured"
}

# Install common dependencies
install_common_dependencies() {
    log "Installing common dependencies..."
    
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y git python3 python3-pip python3-venv build-essential openssl curl
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf update -y
        sudo dnf install -y git python3 python3-pip openssl curl
    else
        error "Unsupported distribution: ${DISTRO}"
    fi
    
    # Create Python virtual environment
    sudo mkdir -p /opt/machine-status
    sudo python3 -m venv /opt/machine-status/venv
    
    log "Common dependencies installed"
}

# Install Python dependencies
install_python_dependencies() {
    log "Installing Python dependencies..."
    
    # Update pip
    sudo /opt/machine-status/venv/bin/pip install --upgrade pip
    
    # Install required packages
    sudo /opt/machine-status/venv/bin/pip install paho-mqtt psutil sqlalchemy psycopg2-binary
    
    log "Python dependencies installed"
}

# Install MQTT Broker
install_mqtt_broker() {
    log "Installing MQTT Broker (Mosquitto)..."
    
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y mosquitto mosquitto-clients
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf install -y mosquitto
    else
        error "Unsupported distribution: ${DISTRO}"
    fi
    
    log "MQTT Broker installed"
}

# Configure MQTT Broker
configure_mqtt_broker() {
    log "Configuring MQTT Broker..."
    
    # Generate random MQTT password
    MQTT_USER="machine_status"
    MQTT_PASS=$(openssl rand -base64 16)
    
    # Create configuration directory
    sudo mkdir -p /etc/machine-status
    
    # Store MQTT credentials in environment file
    sudo tee /etc/machine-status/mqtt.env > /dev/null <<EOL
MQTT_BROKER_ADDRESS=${MQTT_BROKER_ADDRESS}
MQTT_BROKER_PORT=${MQTT_BROKER_PORT}
MQTT_USERNAME=${MQTT_USER}
MQTT_PASSWORD=${MQTT_PASS}
EOL
    sudo chmod 600 /etc/machine-status/mqtt.env
    
    # Configure Mosquitto
    sudo tee /etc/mosquitto/conf.d/machine-status.conf > /dev/null <<EOL
# Machine Status MQTT Configuration
listener ${MQTT_BROKER_PORT}
allow_anonymous false
password_file /etc/mosquitto/passwd
EOL
    
    # Create MQTT user and password
    sudo touch /etc/mosquitto/passwd
    sudo mosquitto_passwd -b /etc/mosquitto/passwd "${MQTT_USER}" "${MQTT_PASS}"
    
    # Restart Mosquitto
    sudo systemctl restart mosquitto
    sudo systemctl enable mosquitto
    
    log "MQTT Broker configured"
}

# Install Machine Status Publisher
install_machine_status_publisher() {
    log "Installing Machine Status Publisher..."
    
    # Create installation directory
    sudo mkdir -p /opt/machine-status/publisher
    
    # Copy publisher script
    sudo tee /opt/machine-status/publisher/machine_status_publisher.py > /dev/null <<'PUBLISHER_SCRIPT'
#!/opt/machine-status/venv/bin/python3

import os
import json
import time
import socket
import logging
import uuid
import platform
import subprocess
from typing import Dict, Any

import paho.mqtt.client as mqtt
import psutil

# Configure logging
logging.basicConfig(
    filename='/var/log/machine-status-publisher.log', 
    level=logging.INFO, 
    format='%(asctime)s - %(levelname)s - %(message)s'
)

class MachineStatusPublisher:
    def __init__(
        self, 
        mqtt_broker_address: str = 'localhost', 
        mqtt_broker_port: int = 1883, 
        mqtt_username: str = 'machine_status', 
        mqtt_password: str = None,
        machine_id: str = None,
        publish_interval: int = 60  # seconds
    ):
        """
        Initialize MQTT Machine Status Publisher
        """
        # MQTT Client setup
        self.client = mqtt.Client()
        self.broker_address = mqtt_broker_address
        self.broker_port = mqtt_broker_port
        
        # Set up MQTT authentication
        if mqtt_username and mqtt_password:
            self.client.username_pw_set(mqtt_username, mqtt_password)
        
        # Set up client callbacks
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        
        # Machine identification
        self.machine_id = machine_id or self._generate_machine_id()
        self.publish_interval = publish_interval
        
        logging.info(f"Initialized Machine Status Publisher with ID: {self.machine_id}")

    def _generate_machine_id(self) -> str:
        """
        Generate a unique machine ID or use existing one
        """
        # Check if machine ID already exists
        id_file = "/etc/machine-status/machine_id"
        if os.path.exists(id_file):
            with open(id_file, 'r') as f:
                return f.read().strip()
        
        # Generate new ID based on hostname and a random UUID
        machine_id = f"{socket.gethostname()}-{str(uuid.uuid4())}"
        
        # Save ID to file
        os.makedirs(os.path.dirname(id_file), exist_ok=True)
        with open(id_file, 'w') as f:
            f.write(machine_id)
        
        return machine_id

    def _on_connect(self, client, userdata, flags, rc):
        """
        MQTT connection callback
        """
        if rc == 0:
            logging.info("Connected to MQTT Broker successfully")
        else:
            logging.error(f"Failed to connect to MQTT Broker. Return code: {rc}")

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

    def _collect_system_info(self) -> Dict[str, Any]:
        """
        Collect system information
        """
        try:
            # Basic system info
            hostname = socket.gethostname()
            ip_address = socket.gethostbyname(hostname)
            
            # CPU info
            cpu_usage = psutil.cpu_percent(interval=1)
            cpu_count = psutil.cpu_count(logical=True)
            
            # Try to get CPU model
            cpu_model = "Unknown"
            try:
                if platform.system() == "Linux":
                    with open('/proc/cpuinfo', 'r') as f:
                        for line in f:
                            if line.startswith('model name'):
                                cpu_model = line.split(':')[1].strip()
                                break
                else:
                    cpu_model = platform.processor()
            except Exception as e:
                logging.warning(f"Could not determine CPU model: {e}")
            
            # Memory info
            memory = psutil.virtual_memory()
            memory_total = self._format_bytes(memory.total)
            memory_available = self._format_bytes(memory.available)
            memory_usage_percent = memory.percent
            
            # Disk info
            disk = psutil.disk_usage('/')
            disk_total = self._format_bytes(disk.total)
            disk_free = self._format_bytes(disk.free)
            disk_usage_percent = disk.percent
            
            # Compile system info
            system_info = {
                "machine_id": self.machine_id,
                "hostname": hostname,
                "ip_address": ip_address,
                "cpu": {
                    "model": cpu_model,
                    "cores": cpu_count,
                    "usage_percent": cpu_usage
                },
                "memory": {
                    "total": memory_total,
                    "available": memory_available,
                    "usage_percent": memory_usage_percent
                },
                "storage": {
                    "total": disk_total,
                    "free": disk_free,
                    "usage_percent": disk_usage_percent
                },
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
            }
            
            return system_info
            
        except Exception as e:
            logging.error(f"Error collecting system information: {e}")
            return {"error": str(e), "machine_id": self.machine_id}

    def _format_bytes(self, bytes_value: int) -> str:
        """
        Format bytes into human-readable format
        """
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_value < 1024.0:
                return f"{bytes_value:.2f} {unit}"
            bytes_value /= 1024.0
        return f"{bytes_value:.2f} PB"

    def publish_status(self):
        """
        Publish machine status to MQTT broker
        """
        try:
            # Collect system info
            system_info = self._collect_system_info()
            
            # Convert to JSON
            json_payload = json.dumps(system_info)
            
            # Publish to MQTT
            result = self.client.publish(
                f"machine_status/{self.machine_id}", 
                json_payload, 
                qos=1
            )
            
            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                logging.info(f"Published status successfully")
            else:
                logging.error(f"Failed to publish status. Error code: {result.rc}")
                
        except Exception as e:
            logging.error(f"Error publishing machine status: {e}")

    def run(self):
        """
        Run the MQTT Machine Status Publisher
        """
        try:
            # Connect to MQTT Broker
            self.client.connect(self.broker_address, self.broker_port, 60)
            
            # Start MQTT loop in background thread
            self.client.loop_start()
            
            logging.info(f"Starting Machine Status Publisher with interval {self.publish_interval} seconds")
            
            # Main loop
            while True:
                self.publish_status()
                time.sleep(self.publish_interval)
                
        except KeyboardInterrupt:
            logging.info("Stopping Machine Status Publisher")
        except Exception as e:
            logging.error(f"Fatal error in publisher: {e}")
        finally:
            # Clean up
            self.client.loop_stop()
            self.client.disconnect()

def main():
    # Load configuration from environment file
    mqtt_config = {}
    
    mqtt_config_file = '/etc/machine-status/mqtt.env'
    if os.path.exists(mqtt_config_file):
        with open(mqtt_config_file, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    mqtt_config[key] = value
    
    # Create and run publisher
    publisher = MachineStatusPublisher(
        mqtt_broker_address=mqtt_config.get('MQTT_BROKER_ADDRESS', 'localhost'),
        mqtt_broker_port=int(mqtt_config.get('MQTT_BROKER_PORT', 1883)),
        mqtt_username=mqtt_config.get('MQTT_USERNAME', 'machine_status'),
        mqtt_password=mqtt_config.get('MQTT_PASSWORD'),
        publish_interval=int(os.getenv('PUBLISH_INTERVAL', 60))
    )
    
    # Run the publisher
    publisher.run()

if __name__ == "__main__":
    main()
PUBLISHER_SCRIPT

    # Set correct permissions
    sudo chmod +x /opt/machine-status/publisher/machine_status_publisher.py
    
    # Create systemd service for publisher
    sudo tee /etc/systemd/system/machine-status-publisher.service > /dev/null <<EOL
[Unit]
Description=Machine Status MQTT Publisher
After=network.target mosquitto.service

[Service]
Type=simple
User=root
EnvironmentFile=/etc/machine-status/mqtt.env
ExecStart=/opt/machine-status/venv/bin/python3 /opt/machine-status/publisher/machine_status_publisher.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd, enable and start service
    sudo systemctl daemon-reload
    sudo systemctl enable machine-status-publisher
    sudo systemctl start machine-status-publisher
    
    log "Machine Status Publisher installed"
}

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
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y postgresql postgresql-contrib
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf install -y postgresql postgresql-server postgresql-contrib
        sudo postgresql-setup --initdb --unit postgresql
        sudo systemctl start postgresql
        sudo systemctl enable postgresql
    else
        error "Unsupported distribution: ${DISTRO}"
    fi
    
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
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    mqtt_config[key] = value
    
    # Load Database configuration
    db_config_file = '/etc/machine-status/db.env'
    if os.path.exists(db_config_file):
        with open(db_config_file, 'r') as f:
            for line in f:
                if '=' in line:
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

# Install client components
install_client() {
    log "Setting up Machine Status Client..."
    
    # Configure system proxy
    configure_system_proxy
    
    # Install common dependencies
    install_common_dependencies
    
    # Install Python dependencies
    install_python_dependencies
    
    # Install Machine Status Publisher
    install_machine_status_publisher
    
    log "Machine Status Client setup complete!"
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