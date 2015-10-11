#!/bin/bash
set -euo pipefail

EX_OK=0
EX_USAGE=64

msg() {
    echo "$@"
}

print_usage() {
    msg "Usage: COMMAND"
    msg ""
    msg "Available commands"
    msg "  agent        Execute the site node agent (Celery worker)"
    msg "  auth-dhcp    Execute the DHCP server for authenticated users"
    msg "               (dnsmasq monitored by a SignalProxyDaemon)"
    msg "  auth-dns     Execute the DNS resolver for the authenticated users (unbound)"
    msg "  database     Execute the database (PostgreSQL)"
    msg "  help         Print this help message"
    msg "  http         Execute the captive portal web server (nginx)"
    msg "  networking   Setup networking (iptables, routing)"
    msg "  portal       Run the captive portal WSGI application (using uWSGI)"
    msg "  radius       Run the RADIUS server (freeRADIUS)"
    msg "  shell        Start a bash shell for debugging"
    msg "  unauth-dhcp  Run the DHCP server for the unauthenticated users"
    msg "               (no-op and handled by the unauth-dns dnsmasq)"
    msg "  unauth-dns   Run the DNS resolver (dnsmasq) for the unauth VLAN"
}

run_agent() {
    exec python3 -m celery.bin.worker --beat --app=hades.agent --uid="${HADES_AGENT_USER}" --gid="${HADES_AGENT_GROUP}" --workdir="${HADES_AGENT_HOME}"
}

run_auth_dns() {
    python3 -m hades.config.generate unbound /etc/hades/unbound.conf
    exec unbound -c /etc/hades/unbound.conf
}

run_auth_dhcp() {
    python3 -m hades.config.generate auth-dnsmasq /etc/hades/auth-dnsmasq.conf
    exec python3 -m hades.dnsmasq.monitor /etc/hades/auth-dnsmasq.conf
}

run_database() {
    # PostgreSQL offers no UID/GID configuration option that allows dropping
    # root privileges after the start of PostgreSQL, one must start PostgreSQL
    # as the postgres user.
    # We cannot use su, because su does fork a child keeps running in the
    # background instead of simply execing and becoming the target program,
    # which caused very behavior with pg_ctl stop.
    # Furthermore su would be PID 1 instead of the postgresql master process,
    # which could potentially break some docker functionality
    if [[ $(whoami) != postgres ]]; then
        msg "This command must be run with the -u postgres option of docker run"
        exit ${EX_USAGE}
    fi
    export PATH="/usr/lib/postgresql/${PG_VERSION}/bin:${PATH}"
    export PGDATA="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER}"
    local PGCONFIG="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}/postgresql.conf"
    mkdir -p "/var/run/postgresql/${PG_VERSION}-${PG_CLUSTER}.pg_stat_tmp"
    pg_ctl start -w -s -o "-c config_file=${PGCONFIG}"
    createuser ${HADES_RADIUS_USER}
    createuser ${HADES_AGENT_USER}
    createuser ${HADES_PORTAL_USER}
    createdb ${HADES_POSTGRESQL_DATABASE}
    python3 -m hades.config.generate postgresql-schema | psql --set=ON_ERROR_STOP=1 --no-psqlrc --single-transaction --file=- ${HADES_POSTGRESQL_DATABASE}
    pg_ctl stop -w -s -o "-c config_file=${PGCONFIG}"
    exec postgres -c config_file=${PGCONFIG}
}

run_http() {
    python3 -m hades.config.generate nginx /etc/hades/nginx
    ln -sf /dev/stdout /var/log/nginx/access.log
    ln -sf /dev/stderr /var/log/nginx/error.log
    exec nginx -c /etc/hades/nginx/nginx.conf
}

run_networking() {
    if [[ "${HADES_CREATE_DUMMY_INTERFACES-False}" = True ]]; then
        for interface in "${HADES_RADIUS_INTERFACE}" "${HADES_VRRP_INTERFACE}" "${HADES_AUTH_INTERFACE}" "${HADES_UNAUTH_INTERFACE}"; do
            if [[ -d "/sys/class/net/${interface}" ]]; then
                continue
            fi
            ip link add name "${interface}" type dummy
            ip link set up dev "${interface}"
        done
    fi
    python3 -m hades.config.generate iptables | iptables-restore
    sysctl net.ipv4.ip_nonlocal_bind=1
    ip rule add fwmark "${HADES_AUTH_FWMARK}"   table "${HADES_AUTH_ROUTING_TABLE}"
    ip rule add fwmark "${HADES_UNAUTH_FWMARK}" table "${HADES_UNAUTH_ROUTING_TABLE}"
    exit ${EX_OK}
}

run_portal() {
    python3 -m hades.config.generate uwsgi /etc/hades/uwsgi.ini
    exec uwsgi --ini=/etc/hades/uwsgi.ini
}

run_radius() {
    python3 -m hades.config.generate freeradius /etc/hades/freeradius
    exec freeradius -f -m -d /etc/hades/freeradius
}

run_shell() {
    exec bash
}

run_unauth_dhcp() {
    echo "DHCP for the unauth VLAN is currently performed by the dnsmasq "
    echo "instance that provides unauth DNS."
    exit ${EX_OK}
}

run_unauth_dns() {
    python3 -m hades.config.generate unauth-dnsmasq /etc/hades/unauth-dnsmasq.conf
    exec dnsmasq -k -C /etc/hades/unauth-dnsmasq.conf
}

main() {
    source <(python3 -m hades.config.export)
    if [[ $# -lt 1 ]]; then
        command=help
    else
        command=$1
        shift
    fi
    case "$command" in
        agent|auth-dhcp|auth-dns|database|http|networking|portal|radius|shell|unauth-dhcp|unauth-dns)
            run_${command//-/_} "$@"
            ;;
        help|-h|--help)
            print_usage
            exit ${EX_OK}
            ;;
        *)
            msg "Unknown command: $command"
            print_usage
            exit ${EX_USAGE}
            ;;
    esac
}

main "$@"
