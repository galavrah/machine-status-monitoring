# Machine Status Monitoring System

## Overview
This system provides a comprehensive solution for monitoring machine status across multiple devices in a network. It consists of two main components:

1. **Machine Status Publisher**: A client-side script that collects and sends machine information to a central server.
2. **Machine Status Server**: A server-side application that receives, stores, and manages machine status data.

## Features
- Collect detailed machine information:
  - Hostname
  - IP Address
  - CPU Model and Usage
  - Memory Usage
  - Storage Information
- Publish machine status at regular intervals
- Store machine status in a PostgreSQL database
- RESTful API for retrieving machine statuses

## Prerequisites
- Ubuntu 20.04 or later
- Python 3.8+
- PostgreSQL
- pip (Python package manager)

## Installation

### Step 1: Clone the Repository
```bash
git clone https://github.com/your-org/machine-status-monitoring.git
cd machine-status-monitoring
```

### Step 2: Run Deployment Script
```bash
sudo bash setup_machine_status.sh
```

The deployment script will:
- Install system and Python dependencies
- Setup PostgreSQL database
- Deploy Machine Status Publisher
- Deploy Machine Status Server

### Configuration

#### Client Configuration
Edit `/usr/local/bin/machine-status-publisher.py`:
- Update `SERVER_URL` with your server's address
- Adjust `PUBLISH_INTERVAL` as needed

#### Server Configuration
Database connection details are stored in `/etc/machine-status/db.env`

## API Endpoints

### POST /machine-status
- Receive machine status updates
- Accepts JSON payload with machine information

### GET /machine-status
- Retrieve machine statuses
- Optional query parameters:
  - `machine_id`: Filter by specific machine
  - `limit`: Limit number of results (default 100)
  - `offset`: Pagination offset (default 0)

## Security Considerations
- Firewall: Allow incoming connections on port 5000
- Use HTTPS in production
- Secure database credentials
- Implement authentication for API endpoints

## Troubleshooting
- Check service status:
  ```bash
  systemctl status machine-status-publisher
  systemctl status machine-status-server
  ```
- View logs:
  ```bash
  tail -f /var/log/machine-status-publisher.log
  tail -f /var/log/machine-status-server.log
  ```
