#!/bin/bash

# Flexible MQTT Broker Installation Script with Proxy Support

set -e

# Proxy configuration
PROXY_HOST="proxy.iil.intel.com"
PROXY_PORT="912"

# Function to install Mosquitto with proxy support
install_mosquitto() {
    echo "Installing Mosquitto MQTT Broker..."
    
    # Install required packages
    sudo apt-get update
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        software-properties-common

    # Attempt to download GPG key with proxy
    echo "Downloading Mosquitto GPG key..."
    
    # Try multiple methods to fetch the key
    MOSQUITTO_KEY_URL="https://mosquitto.org/files/gpg.key"
    
    # Method 1: curl with proxy
    if curl -v -x "http://${PROXY_HOST}:${PROXY_PORT}" "${MOSQUITTO_KEY_URL}" -o mosquitto.gpg.key; then
        echo "Key downloaded via curl with proxy"
    elif curl -v "${MOSQUITTO_KEY_URL}" -o mosquitto.gpg.key; then
        echo "Key downloaded via direct curl"
    else
        echo "Failed to download Mosquitto GPG key"
        exit 1
    fi

    # Verify and add the key
    if gpg --dry-run --import mosquitto.gpg.key; then
        # Convert and store the key
        cat mosquitto.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/mosquitto-archive-keyring.gpg
    else
        echo "Invalid GPG key"
        exit 1
    fi

    # Add repository with the new key method
    echo "deb [signed-by=/usr/share/keyrings/mosquitto-archive-keyring.gpg] https://mosquitto.org/repos/apt $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/mosquitto.list

    # Update and install
    sudo apt-get update
    sudo apt-get install -y mosquitto mosquitto-clients

    # Enable and start service
    sudo systemctl enable mosquitto
    sudo systemctl start mosquitto

    # Clean up key file
    rm -f mosquitto.gpg.key

    echo "Mosquitto MQTT Broker installed successfully!"
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

    # Set proxy for apt if needed
    if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
        echo "Configuring proxy for apt..."
        sudo tee /etc/apt/apt.conf.d/proxy.conf > /dev/null <<EOL
Acquire::http::Proxy "http://${PROXY_HOST}:${PROXY_PORT}";
Acquire::https::Proxy "http://${PROXY_HOST}:${PROXY_PORT}";
EOL
    fi

    # Install Mosquitto
    install_mosquitto
    
    # Configure security
    configure_mosquitto_security
}

# Run main function
main