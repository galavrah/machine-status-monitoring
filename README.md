# MQTT Machine Status Monitoring System

## Overview

This system provides a robust, scalable solution for monitoring machine status across multiple devices using MQTT (Message Queuing Telemetry Transport) protocol. It consists of three main components:

1. **MQTT Broker**: Mosquitto MQTT broker that manages message routing
2. **Machine Status Publisher**: Client-side script that collects and publishes machine status
3. **Machine Status Subscriber**: Server-side script that receives and stores machine status in a database

## Key Features

- Real-time machine status monitoring
- Lightweight and scalable MQTT architecture
- Comprehensive system information collection
- Secure authentication
- Persistent storage in PostgreSQL database

## Architecture Diagram

```
[Machine 1]  →  
[Machine 2]  →   MQTT Broker  →  Subscriber  →  PostgreSQL Database
[Machine N]  →  
```

## Prerequisites

- Ubuntu 20.04 or later
- Python 3.8+
- PostgreSQL
- Mosquitto MQTT Broker
- Required Python packages (see `requirements.txt`)

## Installation Steps

### 1. Install Dependencies

```bash
# Update package lists
sudo apt-get update

# Install required system packages
sudo apt-get install -y \
    python3 \
    python3-pip \
    postgresql \
    mosquitto \
    mosquitto-clients

# Install Python dependencies
pip3 install \
    paho-mqtt \
    psutil \
    sqlalchemy \
    psycopg2-binary \
    netifaces
```

### 2. Configure MQTT Broker

```bash
# Set up Mosquitto password
sudo mosquitto_passwd -c /etc/mosquitto/passwd machine_status

# Configure Mosquitto
sudo nano /etc/mosquitto/conf.d/default.conf
```

Add the following configuration:
```
allow_anonymous false
password_file /etc/mosquitto/passwd

listener 1883 0.0.0.0
protocol mqtt
```

### 3. Setup PostgreSQL Database

```bash
# Create database and user
sudo -u postgres psql
```

```sql
CREATE DATABASE machine_status_db;
CREATE USER machine_status_user WITH PASSWORD 'your_secure_password';
GRANT ALL PRIVILEGES ON DATABASE machine_status_db TO machine_status_user;
```

### 4. Deploy Scripts

```bash
# Create installation directory
sudo mkdir -p /usr/local/bin

# Copy publisher and subscriber scripts
sudo cp machine-status-publisher.py /usr/local/bin/
sudo cp machine-status-subscriber.py /usr/local/bin/

# Set executable permissions
sudo chmod +x /usr/local/bin/machine-status-publisher.py
sudo chmod +x /usr/local/bin/machine-status-subscriber.py
```

### 5. Configure Environment

```bash
# Create configuration directory
sudo mkdir -p /etc/machine-status

# Store MQTT password
echo "your_mqtt_password" | sudo tee /etc/machine-status/mqtt_password
sudo chmod 600 /etc/machine-status/mqtt_password

# Store database connection details
sudo tee /etc/machine-status/database.env > /dev/null <<EOL
DATABASE_URL=postgresql://machine_status_user:your_secure_password@localhost/machine_status_db
MQTT_BROKER_ADDRESS=localhost
MQTT_BROKER_PORT=1883
MQTT_USERNAME=machine_status
MQTT_PASSWORD_FILE=/etc/machine-status/mqtt_password
EOL
```

### 6. Install Systemd Services

```bash
# Copy systemd service files
sudo cp machine-status-publisher.service /etc/systemd/system/
sudo cp machine-status-subscriber.service /etc/systemd/system/

# Reload systemd, enable and start services
sudo systemctl daemon-reload
sudo systemctl enable machine-status-publisher
sudo systemctl enable machine-status-subscriber
sudo systemctl start machine-status-publisher
sudo systemctl start machine-status-subscriber
```

## Monitoring and Troubleshooting

### Check Service Status
```bash
sudo systemctl status machine-status-publisher
sudo systemctl status machine-status-subscriber
```

### View Logs
```bash
journalctl -u machine-status-publisher
journalctl -u machine-status-subscriber
```

## Security Considerations

- Use strong, unique passwords
- Configure firewall to restrict access
- Use TLS for MQTT communication in production
- Regularly update and patch systems

## Customization

You can customize:
- Publish interval
- Collected machine information
- Database schema
- MQTT topics

## Scaling

- Multiple publishers can send to the same broker
- Multiple subscribers can be added for redundancy

## Contributing

Contributions are welcome! Please submit pull requests or open issues.

## License

[Insert your license information]