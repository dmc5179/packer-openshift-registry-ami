#!/bin/bash
set -o errexit -o pipefail

OCP_VER="4.6.8"

dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm

dnf -y update

dnf -y install jq

curl -O https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VER}/openshift-client-linux-${OCP_VER}.tar.gz
curl -O https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VER}/openshift-install-linux-${OCP_VER}.tar.gz

tar -xzf openshift-client-linux-${OCP_VER}.tar.gz
mv oc kubectl /usr/local/bin
chown root.root /usr/local/bin/oc /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/oc /usr/local/bin/kubectl
restorecon -v /usr/local/bin/oc /usr/local/bin/kubectl

rm -f README.md

tar -xzf openshift-install-linux-${OCP_VER}.tar.gz
mv openshift-install /usr/local/bin/
chown root.root /usr/local/bin/openshift-install
chmod 0755 /usr/local/bin/openshift-install
restorecon -v /usr/local/bin/openshift-install
rm -f README.md


export REGISTRY_DIR="/opt/registry/"
export REGISTRY_HOSTNAME="${HOSTNAME}"
export REGISTRY_IP="$(hostname -i)"
export REGISTRY_PORT=5000
export REGISTRY_IMG="docker.io/library/registry:2"

sudo yum -y install podman httpd httpd-tools firewalld skopeo

mkdir -p ${REGISTRY_DIR}/{auth,certs,data}

# Generate the certificate
# TODO: -addext appears not to work on RHEL 7. Works on RHEL 8 and Fedora 31+
#       If SAN is not needed, comment out the -addext line
openssl req -newkey rsa:4096 -nodes -keyout "${REGISTRY_DIR}/certs/domain.key" \
  -x509 -days 365 -out "${REGISTRY_DIR}/certs/domain.crt" \
  -addext "subjectAltName = IP:${REGISTRY_IP},DNS:${HOSTNAME}" \
  -subj "/C=US/ST=VA/L=Chantilly/O=RedHat/OU=RedHat/CN=${HOSTNAME}/"

# Print the certificate
openssl x509 -in "${REGISTRY_DIR}/certs/domain.crt" -text -noout

htpasswd -bBc ${REGISTRY_DIR}/auth/htpasswd dummy dummy

#Make sure to trust the self signed cert we just made
sudo cp -f ${REGISTRY_DIR}/certs/domain.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

sudo systemctl enable --now firewalld
sleep 5
sudo firewall-cmd --add-port=${REGISTRY_PORT}/tcp --zone=internal --permanent
sudo firewall-cmd --add-port=${REGISTRY_PORT}/tcp --zone=public   --permanent
sudo firewall-cmd --add-service=http  --permanent
sudo firewall-cmd --reload

podman run --name registry_server -p ${REGISTRY_PORT}:5000 \
-v ${REGISTRY_DIR}/data:/var/lib/registry:z \
-v ${REGISTRY_DIR}/auth:/auth:z \
-e "REGISTRY_AUTH=htpasswd" \
-e "REGISTRY_AUTH_HTPASSWD_REALM=Registry" \
-e "REGISTRY_HTTP_SECRET=ALongRandomSecretForRegistry" \
-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
-v ${REGISTRY_DIR}/certs:/certs:z \
-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
-e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
--hostname=${REGISTRY_HOSTNAME} \
--conmon-pidfile=/tmp/podman-registry-conman.pid \
--detach \
${REGISTRY_IMG}

# Configure SELinux to allow containers in systemd services
sudo setsebool -P container_manage_cgroup on

sudo bash -c "cat <<EOF >> /etc/systemd/system/registry-container.service

[Unit]
Description=Container Registry

[Service]
Restart=always
ExecStart=/usr/bin/podman start -a registry_server
ExecStop=/usr/bin/podman stop -t 15 registry_server

[Install]
WantedBy=multi-user.target

EOF"

sudo systemctl daemon-reload
sudo systemctl enable --now registry-container.service
sleep 5

jq ".auths |= .+ {\"${REGISTRY_HOSTNAME}:${REGISTRY_PORT}\": { \"auth\": \"ZHVtbXk6ZHVtbXk=\" }}" /tmp/pull-secret.json > /tmp/pull-secret-new.json
mv -f /tmp/pull-secret-new.json /tmp/pull-secret.json

/usr/local/bin/oc adm release mirror \
  -a /tmp/pull-secret.json \
  --from=quay.io/openshift-release-dev/ocp-release:${OCP_VER}-x86_64 \
  --to=${REGISTRY_HOSTNAME}:${REGISTRY_PORT}/ocp4/openshift4
