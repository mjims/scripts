#!/bin/bash
set -e

########################################
# ROOT CHECK
########################################
[ "$EUID" -ne 0 ] && echo "Run with sudo" && exit 1

########################################
# CONFIG
########################################
VPN_DOMAIN="vpn.example.com"
VPN_PORT=1194
VPN_NET="10.8.0"

BASE_WEB=16000
BASE_WIN=20000
BASE_API=19000
BASE_SSH=19700

OVPN_DIR="/etc/openvpn"
EASYRSA_DIR="/etc/openvpn/easy-rsa"

PUBLIC_DIR="/var/www/html/cert"
PUBLIC_URL="https://vpn.example.com/cert"

CLIENT="$1"
[ -z "$CLIENT" ] && echo "Usage: sudo $0 clientname" && exit 1

########################################
# SAFE NUMERIC ID
########################################
ID=$(echo "$CLIENT" | tr -dc '0-9' | sed 's/^0*//')
[ -z "$ID" ] && ID=$((RANDOM % 200 + 20))
[ "$ID" -lt 10 ] && ID=$((ID + 10))

VPN_IP="${VPN_NET}.${ID}"

WEB_PORT=$((BASE_WEB + ID))
WIN_PORT=$((BASE_WIN + ID))
API_PORT=$((BASE_API + ID))
SSH_PORT=$((BASE_SSH + ID))

PASSWORD=$(openssl rand -base64 12)

echo "=== CREATION CLIENT OPENVPN ==="

########################################
# USER / PASS
########################################
touch ${OVPN_DIR}/psw-file
chmod 600 ${OVPN_DIR}/psw-file
grep -q "^${CLIENT} " ${OVPN_DIR}/psw-file || \
echo "${CLIENT} ${PASSWORD}" >> ${OVPN_DIR}/psw-file

########################################
# STATIC IP (CCD)
########################################
mkdir -p ${OVPN_DIR}/ccd
echo "ifconfig-push ${VPN_IP} 255.255.255.0" > ${OVPN_DIR}/ccd/${CLIENT}

########################################
# CERTIFICAT CLIENT
########################################
cd ${EASYRSA_DIR}
./easyrsa --batch build-client-full ${CLIENT} nopass

cp pki/issued/${CLIENT}.crt ${OVPN_DIR}/${CLIENT}.crt
cp pki/private/${CLIENT}.key ${OVPN_DIR}/${CLIENT}.key
cp pki/ca.crt ${OVPN_DIR}/${CLIENT}-ca.crt

########################################
# GENERATE RANDOM PUBLIC TOKEN + FILENAMES
########################################
TOKEN=$(openssl rand -hex 16)
PUBLIC_PATH="${PUBLIC_DIR}/${CLIENT}-${TOKEN}"
PUBLIC_URL_CLIENT="${PUBLIC_URL}/${CLIENT}-${TOKEN}"

mkdir -p ${PUBLIC_PATH}

RAND_CA=$(openssl rand -hex 12).crt
RAND_CRT=$(openssl rand -hex 12).crt
RAND_KEY=$(openssl rand -hex 12).key

cp ${OVPN_DIR}/${CLIENT}-ca.crt ${PUBLIC_PATH}/${RAND_CA}
cp ${OVPN_DIR}/${CLIENT}.crt ${PUBLIC_PATH}/${RAND_CRT}
cp ${OVPN_DIR}/${CLIENT}.key ${PUBLIC_PATH}/${RAND_KEY}

chmod 644 ${PUBLIC_PATH}/*

########################################
# NAT PORTS
########################################
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

########################################
# SAVE IPTABLES
########################################
command -v netfilter-persistent >/dev/null && netfilter-persistent save

########################################
# OUTPUT INFOS
########################################
echo
echo "✅ CLIENT CRÉÉ AVEC SUCCÈS"
echo "User     : $CLIENT"
echo "Password : $PASSWORD"
echo "VPN IP   : $VPN_IP"
echo
echo "Accès :"
echo " WebFig : http://${VPN_DOMAIN}:${WEB_PORT}"
echo " Winbox : ${VPN_DOMAIN}:${WIN_PORT}"
echo " API    : ${VPN_DOMAIN}:${API_PORT}"
echo " SSH    : ssh -p ${SSH_PORT} admin@${VPN_DOMAIN}"
echo
echo "=== URL CERTIFICATS PRIVÉS ==="
echo "${PUBLIC_URL_CLIENT}/${RAND_CA}"
echo "${PUBLIC_URL_CLIENT}/${RAND_CRT}"
echo "${PUBLIC_URL_CLIENT}/${RAND_KEY}"
echo

########################################
# SCRIPT MIKROTIK AUTO
########################################
echo "=== SCRIPT MIKROTIK ==="

cat <<EOF
/tool fetch url="${PUBLIC_URL_CLIENT}/${RAND_CA}" mode=https dst-path=ca.crt
delay 1
/tool fetch url="${PUBLIC_URL_CLIENT}/${RAND_CRT}" mode=https dst-path=${CLIENT}.crt
delay 1
/tool fetch url="${PUBLIC_URL_CLIENT}/${RAND_KEY}" mode=https dst-path=${CLIENT}.key
delay 1

/certificate import file-name="ca.crt" passphrase=""
/certificate import file-name="${CLIENT}.crt" passphrase=""
/certificate import file-name="${CLIENT}.key" passphrase=""

/ppp profile add name="ovpn-${CLIENT}" use-encryption=required only-one=yes change-tcp-mss=yes

/interface ovpn-client add \
 name="ovpn-${CLIENT}" \
 connect-to="${VPN_DOMAIN}" \
 port=${VPN_PORT} \
 user="${CLIENT}" \
 password="${PASSWORD}" \
 profile="ovpn-${CLIENT}" \
 certificate="${CLIENT}" \
 cipher=aes128 \
 auth=sha1 \
 add-default-route=no \
 disabled=no
EOF

echo "==============================="
