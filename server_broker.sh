#!/bin/bash

# MQTT Broker Installation Script for Ubuntu

set -e

# Function to install Mosquitto MQTT Broker
install_mosquitto() {
    echo "Installing Mosquitto MQTT Broker..."
    
    # Import Mosquitto repository key
    wget -q -O - https://mosquitto.org/repos/apt/debian.key | sudo apt-key add -
    
    # Add Mosquitto repository
    sudo add-apt-repository "deb https://mosquitto.org/repos/apt $(lsb_release -cs) main"
    
    # Update package lists
    sudo apt-get update
    
    # Install Mosquitto broker and clients
    sudo apt-get install -y mosquitto mosquitto-clients
    
    # Enable Mosquitto to start on boot
    sudo systemctl enable mosquitto
    
    # Configure basic security
    configure_mosquitto_security
    
    # Start Mosquitto service
    sudo systemctl start mosquitto
    
    echo "Mosquitto MQTT Broker installed and configured!"
}

# Function to configure Mosquitto security
configure_mosquitto_security() {
    echo "Configuring Mosquitto security..."
    
    # Create password file
    sudo mosquitto_passwd -c /etc/mosquitto/passwd machine_status
    
    # Create Mosquitto configuration with authentication
    sudo tee /etc/mosquitto/conf.d/default.conf > /dev/null <<EOL
# Default Mosquitto Configuration
allow_anonymous false
password_file /etc/mosquitto/passwd

# Listener configuration
listener 1883 0.0.0.0
protocol mqtt

# Optional TLS configuration (recommended for production)
# listener 8883
# cafile /path/to/ca.crt
# certfile /path/to/server.crt
# keyfile /path/to/server.key
EOL

    # Set proper permissions
    sudo chown mosquitto:mosquitto /etc/mosquitto/passwd
    sudo chmod 600 /etc/mosquitto/passwd
    
    # Restart Mosquitto to apply changes
    sudo systemctl restart mosquitto
}

# Main installation function
main() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
       echo "This script must be run as root" 
       exit 1
    fi

    # Install Mosquitto
    install_mosquitto
}

# Run main function
main