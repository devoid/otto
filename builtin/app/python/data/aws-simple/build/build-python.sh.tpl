#!/bin/bash

set -o nounset -o errexit -o pipefail -o errtrace

error() {
   local sourcefile=$1
   local lineno=$2
   echo "ERROR at ${sourcefile}:${lineno}; Last logs:"
   grep otto /var/log/syslog | tail -n 20
}
trap 'error "${BASH_SOURCE}" "${LINENO}"' ERR

oe() { "$@" 2>&1 | logger -t otto > /dev/null; }
ol() { echo "[otto] $@"; }

# cloud-config can interfere with apt commands if it's still in progress
ol "Waiting for cloud-config to complete..."
until [[ -f /var/lib/cloud/instance/boot-finished ]]; do
  sleep 0.5
done

ol "Adding apt repositories and updating..."
oe sudo apt-get update
oe sudo apt-get install -y python-software-properties software-properties-common apt-transport-https
oe sudo add-apt-repository -y ppa:fkrull/deadsnakes
oe sudo apt-get update

export PYTHON_VERSION="{{ python_version }}"
export PYTHON_ENTRYPOINT="{{ python_entrypoint }}"

ol "Installing Python, Nginx, and other packages..."
export DEBIAN_FRONTEND=noninteractive
oe sudo apt-get install -y bzr git mercurial build-essential \
  libpq-dev zlib1g-dev software-properties-common \
  nodejs \
  libsqlite3-dev \
  python$PYTHON_VERSION python$PYTHON_VERSION-dev \
  nginx-extras


ol "Installing pip and virtualenv..."
oe sudo bash -c "python$PYTHON_VERSION <(wget -q -O - https://bootstrap.pypa.io/get-pip.py)"
oe sudo -H pip install virtualenv

ol "Creating virtualenv..."
sudo virtualenv --python=/usr/bin/python$PYTHON_VERSION /srv/otto-app/virtualenv

ol "Install gunicorn..."
# we install using pip to support alternate python versions
oe sudo /srv/otto-app/virtualenv/bin/pip -H install gunicorn

ol "Extracting app..."
sudo mkdir -p /srv/otto-app/src
oe sudo tar xf /tmp/otto-app.tgz -C /srv/otto-app/src

ol "Adding application user..."
oe sudo adduser --disabled-password --gecos "" otto-app

ol "Setting permissions..."
oe sudo chown -R otto-app: /srv/otto-app

ol "Configuring gunicorn..."
cat <<GUNICORN | sudo tee /etc/init/gunicorn.conf > /dev/null
description "gunicorn"

start on (filesystem)
stop on runlevel [016]

respawn
setuid otto-app
setgid otto-app
chdir /srv/otto-app/src

exec /srv/otto-app/virtualenv/bin/gunicorn -w 4 $PYTHON_ENTRYPOINT

GUNICORN

ol "Configuring nginx..."

# Need to remove this so nginx reads our site
sudo rm /etc/nginx/sites-enabled/default

cat <<NGINXCONF | sudo tee /etc/nginx/sites-enabled/otto-app.conf > /dev/null
# Generated by Otto
server {
    listen 80;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forward-For \$proxy_add_x_forwarded_for;
    }
}
NGINXCONF

ol "Installing the app..."
if [[ -f /srv/otto-app/src/setup.py ]]; then
    (
        cd /src/otto-app/src
        oe sudo -u otto-app /srv/otto-app/virtualenv/bin/python setup.py install
    )
fi
if [[ -f /srv/otto-app/src/requirements.txt ]]; then
    oe sudo -H -u otto-app /srv/otto-app/virtualenv/bin/pip install -r /srv/otto-app/src/requirements.txt
fi

ol "...done!"
