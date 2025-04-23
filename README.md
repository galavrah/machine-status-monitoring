# Machine Status Monitoring System

## Overview

This system provides a comprehensive solution for monitoring machine status across multiple devices using MQTT and PostgreSQL.

## Architecture

- **Client**: Publishes machine status periodically
- **Server**: Subscribes to machine status and stores in database
- **MQTT Broker**: Routes messages between clients and server

## Prerequisites

- Ubuntu 20.04 or later
- Root/sudo access
- Internet connection
- (Optional) Proxy configuration

## Installation

### Server Installation

```bash
# Download the installer
wget https://raw.githubusercontent.com/galavrah/machine-status-monitoring/refs/heads/main/machine-status-installer.sh

# Make executable
chmod +x machine-status-installer.sh

# Install server components
sudo ./machine-status-installer.sh server
```

### Client Installation

```bash
# Download the installer
wget https://raw.githubusercontent.com/galavrah/machine-status-monitoring/refs/heads/main/machine-status-installer.sh

# Make executable
chmod +x machine-status-installer.sh

# Install client components
sudo ./machine-status-installer.sh client
```

## Configuration

### Proxy Support

If your network requires a proxy:

```bash
# Set proxy environment variables before installation
export PROXY_HOST=proxy.example.com
export PROXY_PORT=912

# Then run the installer
```

### MQTT Broker Configuration

Configuration is stored in `/etc/machine-status/mqtt.env`:
- `MQTT_BROKER_ADDRESS`: Broker hostname
- `MQTT_BROKER_PORT`: Broker port
- `MQTT_USERNAME`: MQTT authentication username
- `MQTT_PASSWORD`: MQTT authentication password

### Database Configuration

Configuration is stored in `/etc/machine-status/db.env`:
- `DATABASE_URL`: PostgreSQL connection string

## Monitoring

### Check Service Status

```bash
# For server
sudo systemctl status machine-status-subscriber

# For client
sudo systemctl status machine-status-publisher
```

### View Logs

```bash
# Server logs
journalctl -u machine-status-subscriber

# Client logs
journalctl -u machine-status-publisher
```

## Security Considerations

- Credentials are stored with restricted permissions
- MQTT requires authentication
- Use HTTPS/TLS in production environments

## Troubleshooting

1. Ensure network connectivity
2. Check MQTT broker status
3. Verify database connection
4. Review service logs