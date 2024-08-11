# Use a base image with a compatible Linux distribution
FROM ubuntu:20.04

# Install required packages and tools
RUN apt-get update && \
    apt-get install -y \
        strongswan \
        xl2tpd \
        iproute2 \
        iputils-ping \
        wget \
        vim \
        tor \
        cron \
        && apt-get clean

# Copy the .env file
COPY .env ./.env

# Set environment variables from .env file
RUN export $(grep -v '^#' /root/.env | xargs) && \
    echo ": PSK \"$IPSEC_PSK\"" > /etc/ipsec.secrets && \
    echo "$IPSEC_IDENTIFIER : EAP \"$IPSEC_PASSWORD\"" >> /etc/ipsec.secrets && \
    echo "$IPSEC_IDENTIFIER * \"$IPSEC_PASSWORD\" *" > /etc/ppp/chap-secrets && \
    echo "$L2TP_SECRET * $IPSEC_IDENTIFIER $IPSEC_PASSWORD" >> /etc/ppp/chap-secrets

# IPsec configuration
RUN export $(grep -v '^#' /root/.env | xargs) && \
    cat <<EOL > /etc/ipsec.conf
config setup
    charon {
        load_modular = yes
        plugins {
            attr {
                cert_policy_oid = no
            }
        }
    }
    uniqueids = no

conn %default
    keyexchange=ikev2
    authby=psk
    ikelifetime=60m
    keylife=20m
    rekeymargin=3m
    keyingtries=1

conn L2TP-IPsec
    authby=psk
    keyexchange=ikev1
    left=%defaultroute
    leftid=$NOIP_DOMAIN
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/1701
    type=transport
    auto=add
    leftsubnet=0.0.0.0/0
    leftfirewall=yes
EOL

# L2TP configuration
RUN export $(grep -v '^#' /root/.env | xargs) && \
    cat <<EOL > /etc/xl2tpd/xl2tpd.conf
[global]
port = 1701

[lns default]
ip range = 192.168.1.100-192.168.1.200
local ip = 192.168.1.1
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TP-Pool
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOL

# PPP options for L2TP
RUN export $(grep -v '^#' /root/.env | xargs) && \
    cat <<EOL > /etc/ppp/options.xl2tpd
require-mschap-v2
refuse-pap
refuse-chap
refuse-mschap
name l2tpd
password $IPSEC_PASSWORD
ms-dns 8.8.8.8
ms-dns 8.8.4.4
EOL

# Configure No-IP DUC (Dynamic Update Client)
RUN wget https://www.noip.com/client/linux/noip-duc-linux.tar.gz && \
    tar xf noip-duc-linux.tar.gz && \
    cd noip-2.1.9-1/ && \
    make install && \
    echo "$NOIP_USERNAME\n$NOIP_PASSWORD\n" | /usr/local/bin/noip2 -C && \
    /usr/local/bin/noip2

# Configure TOR
RUN echo "ControlPort 9051" >> /etc/tor/torrc && \
    echo "CookieAuthentication 0" >> /etc/tor/torrc && \
    echo "DisableNetwork 0" >> /etc/tor/torrc && \
    echo "VirtualAddrNetworkIPv4 10.192.0.0/10" >> /etc/tor/torrc && \
    echo "AutomapHostsOnResolve 1" >> /etc/tor/torrc && \
    echo "TransPort 9040" >> /etc/tor/torrc && \
    echo "DNSPort 5353" >> /etc/tor/torrc && \
    service tor start

# Setup cron job for changing TOR IP every 17 seconds
RUN (crontab -l ; echo "*/$TOR_NEWNYM_INTERVAL * * * * /bin/echo -e 'AUTHENTICATE \"\"\\nSIGNAL NEWNYM\\nQUIT' | nc localhost 9051") | crontab -

# Start services when the container runs
CMD ["sh", "-c", "/usr/local/bin/noip2 && ipsec start && xl2tpd && service tor start && cron && iptables -t nat -A PREROUTING -i ppp0 -p tcp --syn -j REDIRECT --to-ports 9040 && iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-port 5353 && tail -f /dev/null"]
