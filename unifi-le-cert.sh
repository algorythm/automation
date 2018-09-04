#!/usr/bin/env bash
#
# This script is for automatically issuing valid SSL certificates, and install them in the unifi controller
#
# Modified script from here: https://git.sosdg.org/brielle/lets-encrypt-scripts/raw/branch/master/gen-unifi-cert.sh
#   -- Which is modified from here: https://github.com/FarsetLabs/letsencrypt-helper-scripts/blob/master/letsencrypt-unifi.sh
# Modified by: Anders Wiberg Olsen <anders@wiberg.tech>
# Download URL: https://github.com/algorythm/automation
#
# Version: 1.7
# Last Changed: 04/09/2018
#
# 02/02/2016: Fixed some errors with key export/import, removed lame docker requirements
# 02/27/2016: More verbose progress report
# 03/08/2016: Add renew option, reformat code, command line options
# 03/24/2016: More sanity checking, embedding cert
# 10/23/2017: Apparently don't need the ace.jar parts, so disable them
# 02/04/2018: LE disabled tls-sni-01, so switch to just tls-sni, as certbot 0.22 and later automatically fall back to http/80 for auth
# 05/29/2018: Integrate patch from Donald Webster <fryfrog[at]gmail.com> to cleanup and improve tests
# 04/09/2018: Download X3 instead of hardcoding it

# Location of LetsEncrypt binary we use.  Leave unset if you want to let it find automatically
#LEBINARY="/usr/src/letsencrypt/certbot-auto"

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

function usage() {
  echo "Usage: $0 -d <domain> [-e <email>] [-r] [-i]"
  echo "  -d <domain>: The domain name to use."
  echo "  -e <email>: Email address to use for certificate."
  echo "  -r: Renew domain."
  echo "  -i: Insert only, use to force insertion of certificate."
}

while getopts "hird:e:" opt; do
  case $opt in
    i) onlyinsert="yes";;
    r) renew="yes";;
    d) domains+=("$OPTARG");;
    e) email="$OPTARG";;
    h) usage
       exit;;
  esac
done

DEFAULTLEBINARY="/usr/bin/certbot /usr/bin/letsencrypt /usr/sbin/certbot
  /usr/sbin/letsencrypt /usr/local/bin/certbot /usr/local/sbin/certbot
  /usr/local/bin/letsencrypt /usr/local/sbin/letsencrypt
  /usr/src/letsencrypt/certbot-auto /usr/src/letsencrypt/letsencrypt-auto
  /usr/src/certbot/certbot-auto /usr/src/certbot/letsencrypt-auto
  /usr/src/certbot-master/certbot-auto /usr/src/certbot-master/letsencrypt-auto"

if [[ ! -v LEBINARY ]]; then
  for i in ${DEFAULTLEBINARY}; do
    if [[ -x ${i} ]]; then
      LEBINARY=${i}
      echo "Found LetsEncrypt/Certbot binary at ${LEBINARY}"
      break
    fi
  done
fi

# Command line options depending on New or Renew.
NEWCERT="--renew-by-default certonly"
RENEWCERT="-n renew"

# Check for required binaries
if [[ ! -x ${LEBINARY} ]]; then
  echo "Error: LetsEncrypt binary not found in ${LEBINARY} !"
  echo "You'll need to do one of the following:"
  echo "1) Change LEBINARY variable in this script"
  echo "2) Install LE manually or via your package manager and do #1"
  echo "3) Use the included get-letsencrypt.sh script to install it"
  exit 1
fi

if [[ ! -x $( which keytool ) ]]; then
  echo "Error: Java keytool binary not found."
  exit 1
fi

if [[ ! -x $( which openssl ) ]]; then
  echo "Error: OpenSSL binary not found."
  exit 1
fi

if [[ ! -z ${email} ]]; then
  email="--email ${email}"
else
  email=""
fi

shift $((OPTIND -1))
for val in "${domains[@]}"; do
        DOMAINS="${DOMAINS} -d ${val} "
done

MAINDOMAIN=${domains[0]}

if [[ -z ${MAINDOMAIN} ]]; then
  echo "Error: At least one -d argument is required"
  usage
  exit 1
fi

if [[ ${renew} == "yes" ]]; then
  LEOPTIONS="${RENEWCERT}"
else
  LEOPTIONS="${email} ${DOMAINS} ${NEWCERT}"
fi

if [[ ${onlyinsert} != "yes" ]]; then
  echo "Firing up standalone authenticator on TCP port 443 and requesting cert..."
  ${LEBINARY} --server https://acme-v01.api.letsencrypt.org/directory \
              --agree-tos --standalone --preferred-challenges tls-sni ${LEOPTIONS}
fi

if [[ ${onlyinsert} != "yes" ]] && md5sum -c "/etc/letsencrypt/live/${MAINDOMAIN}/cert.pem.md5" &>/dev/null; then
  echo "Cert has not changed, not updating controller."
  exit 0
else
  echo "Cert has changed or -i option was used, updating controller..."
  TEMPFILE=$(mktemp)
  CATEMPFILE=$(mktemp)

  # Identrust cross-signed CA cert needed by the java keystore for import.
  # Can get original here: https://www.identrust.com/certificates/trustid/root-download-x3.html
  echo "Downloading X3 Certificate from LetsEncrypt"
  curl -s https://letsencrypt.org/certs/letsencryptauthorityx3.pem.txt > $CATEMPFILE

  md5sum "/etc/letsencrypt/live/${MAINDOMAIN}/cert.pem" > "/etc/letsencrypt/live/${MAINDOMAIN}/cert.pem.md5"
  echo "Using openssl to prepare certificate..."
  cat "/etc/letsencrypt/live/${MAINDOMAIN}/chain.pem" >> "${CATEMPFILE}"
  openssl pkcs12 -export  -passout pass:aircontrolenterprise \
          -in "/etc/letsencrypt/live/${MAINDOMAIN}/cert.pem" \
          -inkey "/etc/letsencrypt/live/${MAINDOMAIN}/privkey.pem" \
          -out "${TEMPFILE}" -name unifi \
          -CAfile "${CATEMPFILE}" -caname root

  echo "Stopping Unifi controller..."
  systemctl stop unifi

  echo "Removing existing certificate from Unifi protected keystore..."
  keytool -delete -alias unifi -keystore /usr/lib/unifi/data/keystore \
          -deststorepass aircontrolenterprise

  echo "Inserting certificate into Unifi keystore..."
  keytool -trustcacerts -importkeystore \
          -deststorepass aircontrolenterprise \
          -destkeypass aircontrolenterprise \
          -destkeystore /usr/lib/unifi/data/keystore \
          -srckeystore "${TEMPFILE}" -srcstoretype PKCS12 \
          -srcstorepass aircontrolenterprise \
          -alias unifi
  rm -f "${TEMPFILE}" "${CATEMPFILE}"

  echo "Starting Unifi controller..."
  systemctl start unifi

  echo "Done!"
fi
