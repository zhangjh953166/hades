FROM hades-base
MAINTAINER Sebastian Schrader <sebastian.schrader@agdsn.de>

# Delete unwanted systemd units and disable journal forwarding
RUN for i in /etc/systemd /lib/systemd /lib/systemd; do \
        find "$i"/system -path '*.wants/*' -a -not -name '*journal*' -a -not -name '*tmpfiles*' -delete; \
    done \
    && for i in /etc/rc*.d; do \
        find "$i" -type l -name 'S*' -delete; \
    done \
    && sed -i -re 's/^#?(ForwardTo[^=]+)=.*$/\1=no/' /etc/systemd/journald.conf

# Install bower dependencies
COPY src/bower.json /build/
RUN cd /build && bower install --allow-root

# Install hades
COPY src/ /build/
RUN cd /build \
    && python3 setup.py install \
    && python3 setup.py compile_catalog -d hades/portal/translations \
    && python3 setup.py clean \
    && cd / \
    && rm -rf /build/

# Copy hades config to container
COPY configs/example.py /etc/hades/config.py
RUN printf '%s=%s\n' \
        HADES_CONFIG /etc/hades/config.py \
        PGVERSION "$PGVERSION" \
        >/etc/hades/env

# Copy hades systemd units and enable all of them
COPY systemd/ /lib/systemd/system
RUN . /etc/hades/env \
    && cd /lib/systemd/system \
    && for i in hades-*.*; do systemctl enable "$i"; done

CMD ["/lib/systemd/systemd", "--system"]
