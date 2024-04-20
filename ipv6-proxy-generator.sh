#!/bin/bash
# Script must be running from root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root";
  exit 1;
fi;

# Program help info for users
function usage() { 
  echo "Usage: $0  [-s | --subnet <16|32|48|64|80|96|112> proxy subnet (default 64)] 
                                    [-c | --proxy-count <number> count of proxies] 
                                    [-u | --username <string> proxy auth username] 
                                    [-p | --password <string> proxy password]
                                    [--random <bool> generate random username/password for each IPv4 backconnect proxy instead of predefined (default false)] 
                                    [-t | --proxies-type <http|socks5> result proxies type (default http)]
                                    [-r | --rotating-interval <0-59> proxies extarnal address rotating time in minutes (default 0, disabled)]
                                    [--start-port <5000-65536> start port for backconnect ipv4 (default 30000)]
                                    [-l | --localhost <bool> allow connections only for localhost (backconnect on 127.0.0.1)]
                                    [-m | --ipv6-mask <string> constant ipv6 address mask, to which the rotated part is added (or gateaway)
                                          use only if the gateway is different from the subnet address]
                                    [-i | --interface <string> full name of ethernet interface, on which IPv6 subnet was allocated
                                          automatically parsed by default, use ONLY if you have non-standard/additional interfaces on your server]
                                    [-f | --backconnect-proxies-file <string> path to file, in which backconnect proxies list will be written
                                          when proxies start working (default \`~/proxyserver/backconnect_proxies.list\`)]
                                    [-d | --disable-inet6-ifaces-check <bool> disable /etc/network/interfaces configuration check & exit when error
                                          use only if configuration handled by cloud-init or something like this (for example, on Vultr servers)]
                                    [--proxy-start-port <3128-65536> start port for the backconnect proxies (default 3128)]
                                    " 1>&2; exit 1; 
}

options=$(getopt -o ldhs:c:u:p:t:r:m:f:i: --long help,localhost,disable-inet6-ifaces-check,random,subnet:,proxy-count:,username:,password:,proxies-type:,rotating-interval:,ipv6-mask:,interface:,start-port:,backconnect-proxies-file:,proxy-start-port: -- "$@")

# Throw error and show help message if user doesn't provide any arguments
if [ $? != 0 ]; then 
  echo "Error: no arguments provided. Terminating..." >&2 ; 
  usage ; 
fi;

#  Parse command line options
eval set -- "$options"

# Set default values for optional arguments
subnet=64
proxies_type="http"
start_port=30000
proxy_start_port=3128  # Default start port for the backconnect proxies
rotating_interval=0
use_localhost=false
auth=true
use_random_auth=false
inet6_network_interfaces_configuration_check=false
backconnect_proxies_file="default"
# Global network interface name
interface_name="$(ip -br l | awk '$1 !~ "lo|vir|wl|@NONE" { print $1 }' | awk 'NR==1')"
# Log file for script execution
script_log_file="/var/tmp/ipv6-proxy-generator-logs.log"

while true; do
  case "$1" in
    -h | --help ) usage; shift ;;
    -s | --subnet ) subnet="$2"; shift 2 ;;
    -c | --proxy-count ) proxy_count="$2"; shift 2 ;;
    -u | --username ) user="$2"; shift 2 ;;
    -p | --password ) password="$2"; shift 2 ;;
    -t | --proxies-type ) proxies_type="$2"; shift 2 ;;
    -r | --rotating-interval ) rotating_interval="$2"; shift 2;;
    -m | --ipv6-mask ) subnet_mask="$2"; shift 2;;
    -f | --backconnect_proxies_file ) backconnect_proxies_file="$2"; shift 2;;
    -i | --interface ) interface_name="$2"; shift 2;;
    -l | --localhost ) use_localhost=true; shift ;;
    -d | --disable-inet6-ifaces-check ) inet6_network_interfaces_configuration_check=false; shift ;;
    --start-port ) start_port="$2"; shift 2;;
    --proxy-start-port ) proxy_start_port="$2"; shift 2;;
    --random ) use_random_auth=true; shift ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

...

function create_startup_script(){
  delete_file_if_exists $startup_script_path;

  local backconnect_ipv4=$(get_backconnect_ipv4);
  # Add main script that runs proxy server and rotates external ip's, if server is already running
  cat > $startup_script_path <<-EOF
  #!$bash_location

  # Remove leading whitespaces in every string in text
  function dedent() {
    local -n reference="\$1"
    reference="\$(echo "\$reference" | sed 's/^[[:space:]]*//')"
  }

  # Close 3proxy daemon, if it's working
  ps -ef | awk '/[3]proxy/{print \$2}' | while read -r pid; do
    kill \$pid
  done

  # Remove old random ip list before create new one
  if test -f $random_ipv6_list_file; 
  then
    # Remove old ips from interface
    for ipv6_address in \$(cat $random_ipv6_list_file); do ip -6 addr del \$ipv6_address dev $interface_name;done;
    rm $random_ipv6_list_file; 
  fi;

  # Array with allowed symbols in hex (in ipv6 addresses)
  array=( 1 2 3 4 5 6 7 8 9 0 a b c d e f )

  # Generate random hex symbol
  function rh () { echo \${array[\$RANDOM%16]}; }

  rnd_subnet_ip () {
    echo -n $subnet_mask;
    symbol=$subnet
    while (( \$symbol < 128)); do
      if ((\$symbol % 16 == 0)); then echo -n :; fi;
      echo -n \$(rh);
      let "symbol += 4";
    done;
    echo ;
  }

  # Temporary variable to count generated ip's in cycle
  count=1

  # Generate random ips and add them to main interface
  while [ \$count -le $proxy_count ]; do
    ipv6_addr=\$(rnd_subnet_ip)
    ip -6 addr add \$ipv6_addr/$subnet dev $interface_name
    echo \$ipv6_addr >> $random_ipv6_list_file
    let "count += 1";
  done;

  # Generate random usernames and passwords if they are enabled
  if [ "$use_random_auth" = true ]; then
    user="\$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 ; echo '')"
    password="\$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 ; echo '')"
  fi

  # Set 3proxy configuration
  cat > $3proxy_config_path <<-EOF3PROXYCFG
daemon
nserver 8.8.8.8
nserver 8.8.4.4
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
users ${user}:CL:${password}
auth strong
${proxies_type} -i${proxy_start_port} -n
EOF3PROXYCFG

  # Run 3proxy daemon
  /usr/bin/3proxy $3proxy_config_path
EOF

  chmod +x $startup_script_path
}

...
