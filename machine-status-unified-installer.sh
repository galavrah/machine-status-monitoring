#!/bin/bash

# Unified Machine Status Monitoring System Installer
# Supports both server and client installation
# Usage: sudo ./machine-status-unified-installer.sh [server|client] [--ip=<mqtt_server_ip>]

set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values
INSTALL_TYPE=""
MQTT_BROKER_ADDRESS="localhost"
MQTT_BROKER_PORT="1883"
PUBLISH_INTERVAL="5"
OFFLINE_THRESHOLD="10"

# Parse command line arguments
for arg in "$@"; do
  case $arg in
    server)
      INSTALL_TYPE="server"
      shift
      ;;
    client)
      INSTALL_TYPE="client"
      shift
      ;;
    --ip=*)
      MQTT_BROKER_ADDRESS="${arg#*=}"
      shift
      ;;
    --port=*)
      MQTT_BROKER_PORT="${arg#*=}"
      shift
      ;;
    --interval=*)
      PUBLISH_INTERVAL="${arg#*=}"
      shift
      ;;
    --offline-threshold=*)
      OFFLINE_THRESHOLD="${arg#*=}"
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (sudo)"
fi

# Prompt for installation type if not provided
if [ -z "$INSTALL_TYPE" ]; then
    echo "Please select installation type:"
    echo "1) Server (MQTT broker + subscriber + dashboard)"
    echo "2) Client (publisher only)"
    read -p "Enter choice [1-2]: " choice
    
    case $choice in
        1)
            INSTALL_TYPE="server"
            ;;
        2)
            INSTALL_TYPE="client"
            ;;
        *)
            error "Invalid choice"
            ;;
    esac
fi

# Detect Linux distribution
detect_distribution() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        DISTRO_VERSION=$VERSION_ID
        log "Detected Distribution: ${DISTRO} ${DISTRO_VERSION}"
    else
        if [ -f /etc/lsb-release ]; then
            . /etc/lsb-release
            DISTRO=$DISTRIB_ID
            DISTRO_VERSION=$DISTRIB_RELEASE
        elif [ -f /etc/redhat-release ]; then
            DISTRO=$(cat /etc/redhat-release | cut -d' ' -f1)
            DISTRO_VERSION=$(cat /etc/redhat-release | cut -d' ' -f3)
        else
            error "Unable to detect Linux distribution"
        fi
        log "Detected Distribution: ${DISTRO} ${DISTRO_VERSION}"
    fi
}

# Install common dependencies
install_common_dependencies() {
    log "Installing common dependencies..."
    
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y python3 python3-pip python3-venv openssl curl
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf update -y
        sudo dnf install -y python3 python3-pip openssl curl
    else
        error "Unsupported distribution: ${DISTRO}"
    fi
    
    # Create directories
    sudo mkdir -p /opt/machine-status
    sudo mkdir -p /etc/machine-status
    
    # Create Python virtual environment
    sudo python3 -m venv /opt/machine-status/venv
    
    # Upgrade pip
    sudo /opt/machine-status/venv/bin/pip install --upgrade pip
    
    log "Common dependencies installed"
}

# Install client components (publisher)
install_client() {
    log "Installing Machine Status Client..."
    
    # If this is a client-only install, prompt for MQTT broker address
    if [ "$MQTT_BROKER_ADDRESS" = "localhost" ]; then
        read -p "Enter MQTT broker IP address: " user_broker_ip
        if [ ! -z "$user_broker_ip" ]; then
            MQTT_BROKER_ADDRESS=$user_broker_ip
        fi
    fi
    
    # Install Python dependencies
    sudo /opt/machine-status/venv/bin/pip install paho-mqtt psutil netifaces
    
    # Create publisher directory
    sudo mkdir -p /opt/machine-status/publisher
    sudo mkdir -p /var/log
    sudo touch /var/log/machine-status-publisher.log
    sudo chmod 644 /var/log/machine-status-publisher.log
    
    # Create MQTT config
    sudo tee /etc/machine-status/mqtt.env > /dev/null <<EOL
MQTT_BROKER_ADDRESS=${MQTT_BROKER_ADDRESS}
MQTT_BROKER_PORT=${MQTT_BROKER_PORT}
MQTT_USERNAME=machine_status
MQTT_PASSWORD=123456
PUBLISH_INTERVAL=${PUBLISH_INTERVAL}
EOL
    
    # Create publisher script
    log "Creating publisher script with ${PUBLISH_INTERVAL} second interval..."
    sudo tee /opt/machine-status/publisher/machine_status_publisher.py > /dev/null <<'PUBLISHER_SCRIPT'
#!/usr/bin/env python3

import os
import json
import time
import socket
import logging
import uuid
import platform
from typing import Dict, Any

import paho.mqtt.client as mqtt
import psutil
try:
    import netifaces
    has_netifaces = True
except ImportError:
    has_netifaces = False

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
        mqtt_password: str = 123456,
        machine_id: str = None,
        publish_interval: int = 5  # Default to 5 seconds
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
        
        # Add Will message for offline status
        self.client.will_set(
            f"machine_status/{self.machine_id}/status",
            json.dumps({"status": "offline", "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())}),
            qos=1,
            retain=True
        )
        
        logging.info(f"Initialized Machine Status Publisher with ID: {self.machine_id}, publish interval: {self.publish_interval}s")

    def _generate_machine_id(self) -> str:
        """
        Generate a unique machine ID or use existing one
        """
        # Check if machine ID already exists
        id_file = "/etc/machine-status/machine_id"
        if os.path.exists(id_file):
            with open(id_file, 'r') as f:
                return f.read().strip()
        
        # Generate ID based on MAC address if possible
        machine_id = None
        if has_netifaces:
            try:
                # Get MAC address of primary network interface
                interfaces = netifaces.interfaces()
                for iface in interfaces:
                    if iface.startswith(('eth', 'wlan', 'en', 'wlp')):
                        addrs = netifaces.ifaddresses(iface)
                        if netifaces.AF_LINK in addrs:
                            machine_id = addrs[netifaces.AF_LINK][0]['addr'].replace(':', '')
                            break
            except Exception as e:
                logging.error(f"Failed to get MAC address: {e}")
        
        # Fallback to hostname and UUID if MAC address isn't available
        if not machine_id:
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
            # Publish online status immediately on connect
            self._publish_status("online")
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

    def _get_cpu_model(self) -> str:
        """Get CPU model information"""
        try:
            if platform.system() == "Linux":
                with open('/proc/cpuinfo', 'r') as f:
                    for line in f:
                        if "model name" in line:
                            return line.split(':')[1].strip()
            return platform.processor()
        except Exception as e:
            logging.error(f"Failed to read CPU model: {e}")
        return "Unknown CPU"

    def _format_bytes(self, bytes_value: int) -> str:
        """
        Format bytes into human-readable format
        """
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_value < 1024.0:
                return f"{bytes_value:.2f} {unit}"
            bytes_value /= 1024.0
        return f"{bytes_value:.2f} PB"

    def _collect_system_info(self) -> Dict[str, Any]:
        """
        Collect system information
        """
        try:
            # Basic system info
            hostname = socket.gethostname()
            try:
                ip_address = socket.gethostbyname(hostname)
            except:
                ip_address = "Unable to determine IP"
            
            # CPU info
            cpu_usage = psutil.cpu_percent(interval=1)
            cpu_count = psutil.cpu_count(logical=True)
            cpu_model = self._get_cpu_model()
            
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
                "online_status": "online",
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
            }
            
            return system_info
            
        except Exception as e:
            logging.error(f"Error collecting system information: {e}")
            return {"error": str(e), "machine_id": self.machine_id, "online_status": "error"}

    def _publish_status(self, status: str):
        """
        Publish machine status (online/offline)
        """
        try:
            status_payload = {
                "machine_id": self.machine_id,
                "status": status,
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
            }
            
            json_payload = json.dumps(status_payload)
            
            result = self.client.publish(
                f"machine_status/{self.machine_id}/status", 
                json_payload, 
                qos=1,
                retain=True  # Use retain flag for status messages
            )
            
            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                logging.info(f"Published status '{status}' successfully")
            else:
                logging.error(f"Failed to publish status. Error code: {result.rc}")
        
        except Exception as e:
            logging.error(f"Error publishing status: {e}")

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
            self._publish_status("offline")
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
        try:
            with open(mqtt_config_file, 'r') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        mqtt_config[key] = value
        except Exception as e:
            logging.error(f"Error reading MQTT config: {e}")
    
    # Get publish interval from environment or use default (5 seconds)
    publish_interval = int(os.getenv('PUBLISH_INTERVAL', mqtt_config.get('PUBLISH_INTERVAL', 5)))
    
    # Create and run publisher
    publisher = MachineStatusPublisher(
        mqtt_broker_address=mqtt_config.get('MQTT_BROKER_ADDRESS', 'localhost'),
        mqtt_broker_port=int(mqtt_config.get('MQTT_BROKER_PORT', 1883)),
        mqtt_username=mqtt_config.get('MQTT_USERNAME', 'machine_status'),
        mqtt_password=mqtt_config.get('MQTT_PASSWORD', '123456'),
        publish_interval=publish_interval
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
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=-/etc/machine-status/mqtt.env
ExecStart=/opt/machine-status/venv/bin/python3 /opt/machine-status/publisher/machine_status_publisher.py
Restart=on-failure
RestartSec=10
WorkingDirectory=/opt/machine-status
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd, enable and start service
    sudo systemctl daemon-reload
    sudo systemctl enable machine-status-publisher
    sudo systemctl start machine-status-publisher
    
    log "Machine Status Client installed successfully"
    log "Publishing data every ${PUBLISH_INTERVAL} seconds to ${MQTT_BROKER_ADDRESS}:${MQTT_BROKER_PORT}"
    log "View logs with: sudo journalctl -u machine-status-publisher -f"
}

# Install server components (MQTT broker, subscriber, database)
install_server() {
    log "Installing Machine Status Server..."
    
    # Install Mosquitto MQTT broker from standard repositories
    log "Installing MQTT broker (Mosquitto)..."
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        # Install directly from standard repositories
        sudo apt-get install -y mosquitto mosquitto-clients
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf install -y mosquitto
    else
        error "Unsupported distribution for MQTT broker installation: ${DISTRO}"
    fi
    
    # Configure MQTT broker
    sudo tee /etc/mosquitto/conf.d/machine-status.conf > /dev/null <<EOL
# Machine Status MQTT Configuration
listener ${MQTT_BROKER_PORT}
allow_anonymous true

# Persistence
persistence true
persistence_location /var/lib/mosquitto/
EOL

    # Install PostgreSQL
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        sudo apt-get install -y postgresql postgresql-contrib
    elif [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
        sudo dnf install -y postgresql postgresql-server postgresql-contrib
        sudo postgresql-setup --initdb --unit postgresql
        sudo systemctl start postgresql
    else
        error "Unsupported distribution for PostgreSQL installation: ${DISTRO}"
    fi
    
    # Start and enable services
    sudo systemctl enable mosquitto
    sudo systemctl start mosquitto
    sudo systemctl enable postgresql
    sudo systemctl start postgresql
    
    # Configure PostgreSQL
    DB_NAME="machine_status_db"
    DB_USER="machine_status_user"
    DB_PASS=$(openssl rand -base64 12)
    
    # Create database and user
    sudo -u postgres psql <<EOF
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
CREATE DATABASE ${DB_NAME};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF
    
    # Store database credentials
    sudo tee /etc/machine-status/db.env > /dev/null <<EOL
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost/${DB_NAME}
EOL
    sudo chmod 600 /etc/machine-status/db.env
    
    # Store MQTT configuration
    sudo tee /etc/machine-status/mqtt.env > /dev/null <<EOL
MQTT_BROKER_ADDRESS=localhost
MQTT_BROKER_PORT=${MQTT_BROKER_PORT}
MQTT_USERNAME=machine_status
MQTT_PASSWORD=123456
OFFLINE_THRESHOLD=${OFFLINE_THRESHOLD}
EOL
    
    # Install Python dependencies for subscriber
    sudo /opt/machine-status/venv/bin/pip install paho-mqtt sqlalchemy psycopg2-binary flask

    # Install subscriber
    install_subscriber
    
    log "Machine Status Server installed successfully"
    log "MQTT Broker running on port ${MQTT_BROKER_PORT}"
    log "PostgreSQL database: ${DB_NAME}, user: ${DB_USER}, password: ${DB_PASS}"
    log "Offline threshold set to ${OFFLINE_THRESHOLD} seconds"
}

# Install subscriber component
install_subscriber() {
    log "Installing Machine Status Subscriber..."
    
    # Create subscriber directory
    sudo mkdir -p /opt/machine-status/subscriber
    sudo mkdir -p /var/log
    sudo touch /var/log/machine-status-subscriber.log
    sudo chmod 644 /var/log/machine-status-subscriber.log
    
    # Create subscriber script
    sudo tee /opt/machine-status/subscriber/machine_status_subscriber.py > /dev/null <<'SUBSCRIBER_SCRIPT'
#!/usr/bin/env python3

import os
import json
import time
import logging
import threading
from datetime import datetime, timedelta
from typing import Dict, Any

import paho.mqtt.client as mqtt
import sqlalchemy as sa
from sqlalchemy.orm import declarative_base
from sqlalchemy.orm import sessionmaker
from sqlalchemy.sql import func

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
    online_status = sa.Column(sa.String(20), default='unknown')
    last_seen = sa.Column(sa.DateTime, server_default=sa.func.now())
    timestamp = sa.Column(sa.DateTime, server_default=sa.func.now())

class MachineStatusSubscriber:
    def __init__(
        self, 
        broker_address: str = 'localhost', 
        broker_port: int = 1883, 
        username: str = '', 
        password: str = None,
        database_url: str = None,
        offline_threshold: int = 10  # Seconds before marking a machine as offline
    ):
        """
        Initialize MQTT Machine Status Subscriber
        
        :param broker_address: MQTT Broker address
        :param broker_port: MQTT Broker port
        :param username: MQTT Broker username
        :param password: MQTT Broker password
        :param database_url: SQLAlchemy database connection string
        :param offline_threshold: Time in seconds before a machine is considered offline
        """
        # MQTT Client setup
        self.client = mqtt.Client()
        self.broker_address = broker_address
        self.broker_port = broker_port
        self.offline_threshold = offline_threshold
        
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
        if username and password:
            self.client.username_pw_set(username, password)
        
        # Set up client callbacks
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect
        
        # Machine tracking dict to monitor online/offline status
        self.machines = {}
        
        # Start offline detection thread
        self.running = True
        self.offline_detector_thread = threading.Thread(target=self._offline_detector)
        self.offline_detector_thread.daemon = True
        self.offline_detector_thread.start()

    def _on_connect(self, client, userdata, flags, rc):
        """
        MQTT connection callback
        """
        if rc == 0:
            logging.info("Connected to MQTT Broker successfully")
            # Subscribe to machine status topics
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
            data = json.loads(payload)
            
            # Extract topic parts
            topic_parts = msg.topic.split('/')
            
            # Handle status-specific messages
            if len(topic_parts) >= 3 and topic_parts[2] == "status":
                machine_id = topic_parts[1]
                self._handle_status_message(machine_id, data)
                return
            
            # Handle regular machine status updates
            if 'machine_id' in data:
                # Update last seen timestamp and check online status
                machine_id = data.get('machine_id')
                self.machines[machine_id] = {
                    'last_seen': datetime.now(),
                    'status': data.get('online_status', 'online')
                }
                
                # Store in database
                self._store_machine_status(data)
                
                # Print machine data for debugging
                print(f"Received status for machine {machine_id}:")
                print(f"  Hostname: {data.get('hostname', 'Unknown')}")
                print(f"  CPU Usage: {data.get('cpu', {}).get('usage_percent', 'N/A')}%")
                print(f"  Memory Usage: {data.get('memory', {}).get('usage_percent', 'N/A')}%")
                print(f"  Storage Usage: {data.get('storage', {}).get('usage_percent', 'N/A')}%")
                print(f"  Status: {data.get('online_status', 'online')}")
                print("---")
                
                logging.info(f"Received status for machine {machine_id}")
            else:
                logging.warning(f"Received message without machine_id: {data}")
        
        except json.JSONDecodeError:
            logging.error(f"Failed to decode JSON from topic {msg.topic}")
        except Exception as e:
            logging.error(f"Error processing message: {e}")

    def _handle_status_message(self, machine_id: str, data: Dict):
        """
        Handle explicit status messages
        """
        status = data.get('status', 'unknown')
        logging.info(f"Received explicit status '{status}' for machine {machine_id}")
        
        # Update machine status in tracking dict
        if machine_id not in self.machines:
            self.machines[machine_id] = {
                'last_seen': datetime.now(),
                'status': status
            }
        else:
            self.machines[machine_id]['status'] = status
            
            # If machine is coming online, update last_seen
            if status == 'online':
                self.machines[machine_id]['last_seen'] = datetime.now()
        
        # Update status in database
        self._update_machine_status(machine_id, status)

    def _offline_detector(self):
        """
        Background thread to detect offline machines
        """
        while self.running:
            now = datetime.now()
            offline_threshold = timedelta(seconds=self.offline_threshold)
            
            try:
                for machine_id, info in list(self.machines.items()):
                    # Skip machines that are already marked offline
                    if info['status'] == 'offline':
                        continue
                        
                    # Check if machine hasn't been seen recently
                    if now - info['last_seen'] > offline_threshold:
                        logging.info(f"Machine {machine_id} is offline (no data for {self.offline_threshold}s)")
                        self.machines[machine_id]['status'] = 'offline'
                        
                        # Update status in database
                        self._update_machine_status(machine_id, 'offline')
            except Exception as e:
                logging.error(f"Error in offline detector: {e}")
                
            # Sleep for a short time
            time.sleep(2)

    def _update_machine_status(self, machine_id: str, status: str):
        """
        Update machine online status in the database
        """
        try:
            session = self.Session()
            
            # Find the latest record for this machine
            latest = session.query(MachineStatus)\
                .filter(MachineStatus.machine_id == machine_id)\
                .order_by(MachineStatus.timestamp.desc())\
                .first()
                
            if latest:
                # Update the status
                latest.online_status = status
                if status == 'online':
                    latest.last_seen = datetime.now()
                    
                session.commit()
                logging.info(f"Updated status for machine {machine_id} to {status}")
            else:
                logging.warning(f"No records found for machine {machine_id} to update status")
                
        except Exception as e:
            session.rollback()
            logging.error(f"Error updating machine status: {e}")
        finally:
            session.close()

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
                storage_usage=machine_info.get('storage', {}).get('usage_percent', 0),
                online_status=machine_info.get('online_status', 'online'),
                last_seen=datetime.now()
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
            logging.info(f"Starting MQTT Machine Status Subscriber with {self.offline_threshold}s offline threshold")
            self.client.loop_forever()
        
        except Exception as e:
            logging.error(f"Fatal error in subscriber: {e}")
        finally:
            # Clean up
            self.running = False
            if self.offline_detector_thread.is_alive():
                self.offline_detector_thread.join(timeout=1)
            self.client.disconnect()

def main():
    # Load configuration from environment files
    mqtt_config = {}
    db_config = {}
    
    # Load MQTT configuration
    mqtt_config_file = '/etc/machine-status/mqtt.env'
    if os.path.exists(mqtt_config_file):
        try:
            with open(mqtt_config_file, 'r') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        mqtt_config[key] = value
        except Exception as e:
            logging.error(f"Error reading MQTT config: {e}")
    
    # Load Database configuration
    db_config_file = '/etc/machine-status/db.env'
    if os.path.exists(db_config_file):
        try:
            with open(db_config_file, 'r') as f:
                for line in f:
                    if '=' in line:
                        key, value = line.strip().split('=', 1)
                        db_config[key] = value
        except Exception as e:
            logging.error(f"Error reading database config: {e}")
    
    # Get offline threshold from environment or use default (10 seconds)
    offline_threshold = int(os.getenv('OFFLINE_THRESHOLD', mqtt_config.get('OFFLINE_THRESHOLD', 10)))
    
    # Get database URL from config or environment
    database_url = db_config.get('DATABASE_URL') or os.getenv('DATABASE_URL')
    
    # Get MQTT configuration
    broker_address = mqtt_config.get('MQTT_BROKER_ADDRESS', 'localhost')
    broker_port = int(mqtt_config.get('MQTT_BROKER_PORT', 1883))
    username = mqtt_config.get('MQTT_USERNAME', 'machine_status')
    password = mqtt_config.get('MQTT_PASSWORD', '123456')
    
    print(f"Starting subscriber on {broker_address}:{broker_port}")
    print(f"Using database: {database_url if database_url else 'Not configured'}")
    print(f"Offline threshold: {offline_threshold} seconds")
    
    # Create and run subscriber
    subscriber = MachineStatusSubscriber(
        broker_address=broker_address,
        broker_port=broker_port,
        username=username,
        password=password,
        database_url=database_url,
        offline_threshold=offline_threshold
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
EnvironmentFile=-/etc/machine-status/mqtt.env
EnvironmentFile=-/etc/machine-status/db.env
ExecStart=/opt/machine-status/venv/bin/python3 /opt/machine-status/subscriber/machine_status_subscriber.py
Restart=on-failure
RestartSec=10
WorkingDirectory=/opt/machine-status
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd, enable and start service
    sudo systemctl daemon-reload
    sudo systemctl enable machine-status-subscriber
    sudo systemctl start machine-status-subscriber
    
    log "Machine Status Subscriber installed successfully"
    log "Offline threshold set to ${OFFLINE_THRESHOLD} seconds"
    log "View logs with: sudo journalctl -u machine-status-subscriber -f"
    
    # Create a simple monitor script for command-line viewing
    sudo tee /opt/machine-status/subscriber/monitor.py > /dev/null <<'MONITOR_SCRIPT'
#!/usr/bin/env python3

import os
import json
import time
import curses
from typing import Dict, Any, List, Tuple
import paho.mqtt.client as mqtt

# Machine status storage
machines = {}

def on_connect(client, userdata, flags, rc):
    """Connect callback - subscribe to all machine status topics"""
    if rc == 0:
        print("Connected to MQTT broker")
        client.subscribe("machine_status/#")
    else:
        print(f"Failed to connect to MQTT broker, return code {rc}")

def on_message(client, userdata, msg):
    """Message callback - process incoming machine status"""
    try:
        # Decode payload
        payload = msg.payload.decode('utf-8')
        data = json.loads(payload)
        
        # Extract topic parts
        topic_parts = msg.topic.split('/')
        
        # Handle status-specific messages
        if len(topic_parts) >= 3 and topic_parts[2] == "status":
            machine_id = topic_parts[1]
            if machine_id in machines:
                machines[machine_id]["online_status"] = data.get("status", "unknown")
            return
        
        # Handle regular machine status updates
        if 'machine_id' in data:
            machine_id = data.get('machine_id')
            machines[machine_id] = {
                "hostname": data.get('hostname', 'Unknown'),
                "ip_address": data.get('ip_address', 'Unknown'),
                "cpu_usage": data.get('cpu', {}).get('usage_percent', 0),
                "memory_usage": data.get('memory', {}).get('usage_percent', 0),
                "storage_usage": data.get('storage', {}).get('usage_percent', 0),
                "online_status": data.get('online_status', 'online'),
                "last_seen": time.time()
            }
    except Exception as e:
        print(f"Error processing message: {e}")

def format_status(status: str) -> Tuple[str, int]:
    """Format and colorize the status string"""
    if status == "online":
        return "ONLINE", curses.COLOR_GREEN
    elif status == "offline":
        return "OFFLINE", curses.COLOR_RED
    else:
        return "UNKNOWN", curses.COLOR_YELLOW

def draw_screen(stdscr):
    """Draw the monitoring screen"""
    # Clear screen
    stdscr.clear()
    
    # Initialize colors
    curses.start_color()
    curses.init_pair(1, curses.COLOR_GREEN, curses.COLOR_BLACK)
    curses.init_pair(2, curses.COLOR_RED, curses.COLOR_BLACK)
    curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLACK)
    curses.init_pair(4, curses.COLOR_CYAN, curses.COLOR_BLACK)
    
    # Get screen dimensions
    max_y, max_x = stdscr.getmaxlines(), stdscr.getmaxyx()[1]
    
    # Draw header
    header = "Machine Status Monitor"
    stdscr.addstr(0, max_x//2 - len(header)//2, header, curses.A_BOLD)
    stdscr.addstr(1, 0, "=" * max_x)
    
    # Column headers
    headers = ["Hostname", "IP Address", "CPU", "Memory", "Disk", "Status", "Last Seen"]
    col_widths = [20, 15, 8, 8, 8, 10, 15]
    
    # Draw column headers
    x_pos = 2
    for i, header in enumerate(headers):
        stdscr.addstr(2, x_pos, header, curses.A_BOLD)
        x_pos += col_widths[i] + 2
    
    stdscr.addstr(3, 0, "-" * max_x)
    
    # Draw machine data
    row = 4
    sorted_machines = sorted(machines.items(), key=lambda x: x[1]["hostname"])
    
    for machine_id, data in sorted_machines:
        if row >= max_y - 2:
            break
            
        # Calculate time since last seen
        last_seen = "Just now"
        if "last_seen" in data:
            seconds = time.time() - data["last_seen"]
            if seconds < 60:
                last_seen = f"{int(seconds)}s ago"
            elif seconds < 3600:
                last_seen = f"{int(seconds/60)}m ago"
            else:
                last_seen = f"{int(seconds/3600)}h ago"
        
        # Format status
        status_text, status_color = format_status(data.get("online_status", "unknown"))
        
        # Draw row
        x_pos = 2
        stdscr.addstr(row, x_pos, data.get("hostname", "Unknown")[:col_widths[0]])
        x_pos += col_widths[0] + 2
        
        stdscr.addstr(row, x_pos, data.get("ip_address", "Unknown")[:col_widths[1]])
        x_pos += col_widths[1] + 2
        
        stdscr.addstr(row, x_pos, f"{data.get('cpu_usage', 0):.1f}%")
        x_pos += col_widths[2] + 2
        
        stdscr.addstr(row, x_pos, f"{data.get('memory_usage', 0):.1f}%")
        x_pos += col_widths[3] + 2
        
        stdscr.addstr(row, x_pos, f"{data.get('storage_usage', 0):.1f}%")
        x_pos += col_widths[4] + 2
        
        stdscr.addstr(row, x_pos, status_text, curses.color_pair(status_color))
        x_pos += col_widths[5] + 2
        
        stdscr.addstr(row, x_pos, last_seen)
        
        row += 1
    
    # Draw footer
    stdscr.addstr(max_y-2, 0, "=" * max_x)
    footer = "Press 'q' to quit - Updated: " + time.strftime("%Y-%m-%d %H:%M:%S")
    stdscr.addstr(max_y-1, 2, footer)
    
    # Refresh the screen
    stdscr.refresh()

def monitor_loop(stdscr):
    """Main monitoring loop"""
    # Set up MQTT client
    client = mqtt.Client()
    client.on_connect = on_connect
    client.on_message = on_message
    
    # Load MQTT configuration
    mqtt_config = {}
    mqtt_config_file = '/etc/machine-status/mqtt.env'
    if os.path.exists(mqtt_config_file):
        with open(mqtt_config_file, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    mqtt_config[key] = value
    
    # Connect to broker
    broker_address = mqtt_config.get('MQTT_BROKER_ADDRESS', 'localhost')
    broker_port = int(mqtt_config.get('MQTT_BROKER_PORT', 1883))
    username = mqtt_config.get('MQTT_USERNAME', 'machine_status')
    password = mqtt_config.get('MQTT_PASSWORD', '123456')
    
    if username and password:
        client.username_pw_set(username, password)
    
    print(f"Connecting to MQTT broker at {broker_address}:{broker_port}...")
    client.connect(broker_address, broker_port, 60)
    client.loop_start()
    
    # Set up screen
    curses.curs_set(0)  # Hide cursor
    stdscr.timeout(1000)  # Set getch timeout to 1 second
    
    # Main loop
    try:
        while True:
            draw_screen(stdscr)
            key = stdscr.getch()
            if key == ord('q'):
                break
    finally:
        client.loop_stop()
        client.disconnect()

def main():
    # Run with curses
    curses.wrapper(monitor_loop)

if __name__ == "__main__":
    main()
MONITOR_SCRIPT

    # Set execute permissions
    sudo chmod +x /opt/machine-status/subscriber/monitor.py
    
    # Create a convenience command
    sudo tee /usr/local/bin/machine-monitor > /dev/null <<EOL
#!/bin/bash
/opt/machine-status/venv/bin/python3 /opt/machine-status/subscriber/monitor.py
EOL
    sudo chmod +x /usr/local/bin/machine-monitor
    
    log "Created command-line monitoring tool"
    log "Run 'machine-monitor' to view machine statuses in real-time"
}

# Main installation flow
main() {
    log "Starting Machine Status Monitoring System Installation"
    
    # Detect Linux distribution
    detect_distribution
    
    # Install common dependencies
    install_common_dependencies
    
    # Perform installation based on installation type
    if [ "$INSTALL_TYPE" = "server" ]; then
        install_server
    elif [ "$INSTALL_TYPE" = "client" ]; then
        install_client
    else
        error "Invalid installation type: $INSTALL_TYPE"
    fi
    
    log "Installation completed successfully!"
    
    # Print summary
    if [ "$INSTALL_TYPE" = "server" ]; then
        log "Server components installed:"
        log " - MQTT Broker (listening on port ${MQTT_BROKER_PORT})"
        log " - PostgreSQL Database"
        log " - Machine Status Subscriber (offline threshold: ${OFFLINE_THRESHOLD}s)"
        log " - Command-line monitoring tool (run 'machine-monitor')"
        log ""
        log "You can now install clients using:"
        log "  sudo ./machine-status-unified-installer.sh client --ip=$(hostname -I | awk '{print $1}')"
    elif [ "$INSTALL_TYPE" = "client" ]; then
        log "Client components installed:"
        log " - Machine Status Publisher (publishing every ${PUBLISH_INTERVAL} seconds)"
        log " - Connected to MQTT broker at ${MQTT_BROKER_ADDRESS}:${MQTT_BROKER_PORT}"
    fi
}

# Run main installation
main