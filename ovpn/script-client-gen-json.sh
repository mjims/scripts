#!/bin/bash
set -e

#############################################
# ROOT CHECK
#############################################
[ "$EUID" -ne 0 ] && echo "Run with sudo" && exit 1

#############################################
# CONFIG
#############################################
VPN_DOMAIN="vpn.example.com"
VPN_PORT=1194
VPN_NET="10.8.0"

BASE_WEB=16000
BASE_WIN=20000
BASE_API=19000
BASE_SSH=19700

OVPN_DIR="/etc/openvpn"
EASYRSA_DIR="/etc/openvpn/easy-rsa"

# dossier public Laravel (non listable via .htaccess/nginx)
PUBLIC_CERT_DIR="/var/www/path"
PUBLIC_URL="https://example.com/path"

CLIENT="$1"
[ -z "$CLIENT" ] && echo "Usage: sudo $0 clientname" && exit 1

#############################################
# UNIQUE ID GENERATOR
#############################################
gen_id() {
  echo "$(date +%s%N)$(openssl rand -hex 6)"
}

#############################################
# NUMERIC ID SAFE
#############################################
ID=$(echo "$CLIENT" | tr -dc '0-9' | sed 's/^0*//')
[ -z "$ID" ] && ID=$((RANDOM % 200 + 20))
[ "$ID" -lt 10 ] && ID=$((ID + 10))

VPN_IP="${VPN_NET}.${ID}"

WEB_PORT=$((BASE_WEB + ID))
WIN_PORT=$((BASE_WIN + ID))
API_PORT=$((BASE_API + ID))
SSH_PORT=$((BASE_SSH + ID))

PASSWORD=$(openssl rand -base64 12)

#############################################
# UNIQUE FILENAMES
#############################################
RAND_CA="$(gen_id)-ca.crt"
RAND_CRT="$(gen_id)-client.crt"
RAND_KEY="$(gen_id)-client.key"

#############################################
# CREATE OPENVPN USER
#############################################
touch ${OVPN_DIR}/psw-file
chmod 600 ${OVPN_DIR}/psw-file
grep -q "^${CLIENT} " ${OVPN_DIR}/psw-file || \
echo "${CLIENT} ${PASSWORD}" >> ${OVPN_DIR}/psw-file

#############################################
# FIXED IP CCD
#############################################
mkdir -p ${OVPN_DIR}/ccd
echo "ifconfig-push ${VPN_IP} 255.255.255.0" > ${OVPN_DIR}/ccd/${CLIENT}

#############################################
# CERT GENERATION
#############################################
cd ${EASYRSA_DIR}
./easyrsa --batch build-client-full ${CLIENT} nopass

#############################################
# COPY TO PUBLIC STORAGE
#############################################
mkdir -p ${PUBLIC_CERT_DIR}

cp pki/ca.crt               "${PUBLIC_CERT_DIR}/${RAND_CA}"
cp pki/issued/${CLIENT}.crt "${PUBLIC_CERT_DIR}/${RAND_CRT}"
cp pki/private/${CLIENT}.key "${PUBLIC_CERT_DIR}/${RAND_KEY}"

chmod 600 "${PUBLIC_CERT_DIR}/"*

#############################################
# NAT RULES
#############################################
iptables -t nat -C PREROUTING -p tcp --dport ${WEB_PORT} -j DNAT --to ${VPN_IP}:80 2>/dev/null || \
iptables -t nat -A PREROUTING -p tcp --dport ${WEB_PORT} -j DNAT --to ${VPN_IP}:80

iptables -t nat -C PREROUTING -p tcp --dport ${WIN_PORT} -j DNAT --to ${VPN_IP}:8291 2>/dev/null || \
iptables -t nat -A PREROUTING -p tcp --dport ${WIN_PORT} -j DNAT --to ${VPN_IP}:8291

iptables -t nat -C PREROUTING -p tcp --dport ${API_PORT} -j DNAT --to ${VPN_IP}:8728 2>/dev/null || \
iptables -t nat -A PREROUTING -p tcp --dport ${API_PORT} -j DNAT --to ${VPN_IP}:8728

iptables -t nat -C PREROUTING -p tcp --dport ${SSH_PORT} -j DNAT --to ${VPN_IP}:22 2>/dev/null || \
iptables -t nat -A PREROUTING -p tcp --dport ${SSH_PORT} -j DNAT --to ${VPN_IP}:22

iptables -C FORWARD -d ${VPN_IP} -j ACCEPT 2>/dev/null || iptables -A FORWARD -d ${VPN_IP} -j ACCEPT
iptables -C FORWARD -s ${VPN_IP} -j ACCEPT 2>/dev/null || iptables -A FORWARD -s ${VPN_IP} -j ACCEPT

command -v netfilter-persistent >/dev/null && netfilter-persistent save

#############################################
# URLS
#############################################
URL_CA="${PUBLIC_URL}/${RAND_CA}"
URL_CRT="${PUBLIC_URL}/${RAND_CRT}"
URL_KEY="${PUBLIC_URL}/${RAND_KEY}"

#############################################
# JSON OUTPUT FOR LARAVEL
#############################################
cat <<JSON
{
  "client": "${CLIENT}",
  "password": "${PASSWORD}",
  "vpn_ip": "${VPN_IP}",

  "ports": {
    "webfig": ${WEB_PORT},
    "winbox": ${WIN_PORT},
    "api": ${API_PORT},
    "ssh": ${SSH_PORT}
  },

  "access": {
    "webfig": "http://${VPN_DOMAIN}:${WEB_PORT}",
    "winbox": "${VPN_DOMAIN}:${WIN_PORT}",
    "api": "${VPN_DOMAIN}:${API_PORT}",
    "ssh": "ssh -p ${SSH_PORT} admin@${VPN_DOMAIN}"
  },

  "certificates": {
    "ca": "${URL_CA}",
    "client_crt": "${URL_CRT}",
    "client_key": "${URL_KEY}"
  },

  "mikrotik_script": "/tool fetch url=${URL_CA} mode=https dst-path=ca.crt; \
delay 1; \
/tool fetch url=${URL_CRT} mode=https dst-path=${CLIENT}.crt; \
delay 1; \
/tool fetch url=${URL_KEY} mode=https dst-path=${CLIENT}.key; \
delay 1; \
/certificate import file-name=ca.crt; \
/certificate import file-name=${CLIENT}.crt; \
/certificate import file-name=${CLIENT}.key; \
/ppp profile add name=ovpn-${CLIENT} use-encryption=required only-one=yes change-tcp-mss=yes; \
/interface ovpn-client add name=ovpn-${CLIENT} connect-to=${VPN_DOMAIN} port=${VPN_PORT} user=${CLIENT} password=${PASSWORD} profile=ovpn-${CLIENT} certificate=${CLIENT} cipher=aes128 auth=sha1 add-default-route=no disabled=no"
}
JSON
