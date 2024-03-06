#!/bin/bash

# Function to execute the appropriate Docker Compose command based on availability
docker_compose_exec() {
  local action=$1

  if docker compose version >/dev/null 2>&1; then
    # Use integrated compose command
    echo "Using 'docker compose' to ${action} services..."
    docker compose ${action}
  elif command_exists "docker-compose"; then
    # Use standalone docker-compose binary
    echo "Using 'docker-compose' to ${action} services..."
    docker-compose ${action}
  else
    echo "Neither 'docker compose' nor 'docker-compose' command is available. Please install Docker Compose."
    exit 1
  fi
}

# Check if a command exists in the PATH
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Main script logic based on the passed argument
case "$1" in
  start)
    docker_compose_exec "up -d"
    ;;
  stop)
    docker_compose_exec "down"
    ;;
  setup)
    echo "Setting up the lab..."
    docker compose up -d
# Get the IP address from ens18 interface
IP=$(ip addr show ens18 | grep 'inet\b' | awk '{print $2}' | cut -d/ -f1)

# Check if IP was successfully obtained
if [ -z "$IP" ]; then
    echo "Could not obtain IP from ens18. Exiting."
    exit 1
fi

# List of container names
containers=("cm" "indexer-1" "indexer-2" "sh1" "deployment" "monitor" "license")

docker exec -i proxy sh -c 'mkdir -p /etc/traefik/'

# Create and populate traefik.yml inside the proxy container
docker exec -i proxy sh -c 'cat > /etc/traefik/traefik.yml' <<EOF
global:
  checkNewVersion: false
  sendAnonymousUsage: false

entryPoints:
  web:
    address: :80
  websecure:
    address: :443

api:
  insecure: true
  dashboard: true

providers:
  file:
    filename: /etc/traefik/splunk.yml
    watch: true
EOF

docker exec -i proxy sh -c 'echo "http:" > /etc/traefik/splunk.yml'
docker exec -i proxy sh -c 'echo "  routers:" >> /etc/traefik/splunk.yml'

# Loop through containers to append configurations to splunk.yml
for container in "${containers[@]}"; do
    # Prepare the configuration to append
    config="    ${container}:
      rule: \"Host(\`${IP}\`) && PathPrefix(\`/${container}\`)\"
      service: \"${container}\"
      entryPoints:
        - \"web\""

    # Append the configuration for each container
    docker exec -i proxy sh -c "echo '$config' >> /etc/traefik/splunk.yml"
done

docker exec -i proxy sh -c 'echo "  services: " >> /etc/traefik/splunk.yml'

for container in "${containers[@]}"; do
    # Prepare the configuration to append
    config="    ${container}:
      loadBalancer:
        servers:
          - url: \"http://${container}:8000\""

    # Append the configuration for each container
    docker exec -i proxy sh -c "echo '$config' >> /etc/traefik/splunk.yml"
done

echo "Traefik configuration files have been created in the proxy container."
docker restart proxy

# -------------------------------------------------------------------------------------------

# List of container names
containers=("cm" "indexer-1" "indexer-2" "sh1" "deployment" "monitor" "license")


# Path to the lab app's local directory in the Splunk container
LAB_APP_DIR="/opt/splunk/etc/apps/lab/local"

# Iterate over each container
for container in "${containers[@]}"; do
    # Define the root endpoint dynamically using the container name
    ROOT_ENDPOINT="/$container"
    WEB_CONF_CONTENT="[settings]\nroot_endpoint = $ROOT_ENDPOINT"

    # Check if the lab app's local directory exists and create it if not
    docker exec -u splunk "$container" bash -c "[ -d $LAB_APP_DIR ] || mkdir -p $LAB_APP_DIR"
    
    # Create the web.conf in the lab app's local directory with dynamic content
    echo -e "$WEB_CONF_CONTENT" | docker exec -i -u splunk "$container" bash -c "cat > $LAB_APP_DIR/web.conf"
        
    echo "Updated web.conf for container $container"
done
docker compose restart
# Note: This script does not restart Splunk to apply changes. You may need to manually restart Splunk in each container or add a command to do so here.
    ;;
  delete)
    docker_compose_exec "down -v"
    ;;
  *)
    echo "Invalid argument. Use 'start', 'stop', 'setup', or 'delete'."
    exit 1
    ;;
esac
