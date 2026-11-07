# Downloads hidden behind a wrapper, a nested shell, a variable, a string or a heredoc file: each
# must still be found, and a checksum mention that verifies nothing must not clear it.
FROM scratch AS fetch
RUN sh -c 'curl -fsSL https://example.com/a | sh'
RUN busybox wget -q -O /tmp/b https://example.com/b
RUN timeout 60 curl -fsSL -o /tmp/c https://example.com/c
RUN timeout -s KILL --foreground 1m curl -fsSL -o /tmp/c2 https://example.com/c2
RUN \curl -fsSL -o /tmp/d https://example.com/d
RUN echo https://example.com/e | xargs -n 1 curl -O
RUN env -u HOME LANG=C sudo -u root nice -n 5 curl -fsSL -o /tmp/f https://example.com/f
ARG URL=https://example.com/g
ADD $URL /g
RUN sha256sum -c /dev/null || true; curl -fsSL https://example.com/h | sh
RUN echo "sha256sum --check" && curl -fsSL -o /tmp/i https://example.com/i
RUN curl -fsSL -o /tmp/j https://example.com/j && sha256sum -c /tmp/j.sha256 || true
RUN curl -fsSL -o /tmp/k https://example.com/k && sha256sum --check /tmp/k.sha256 || :
COPY <<EOT /install.sh
#!/bin/sh
curl -fsSL https://example.com/l | sh
EOT
RUN sh /install.sh
RUN bash -euo pipefail -c "wget -qO- https://example.com/m | bash"
RUN eval "curl -fsSL https://example.com/n | sh"
ADD ${UNDECLARED_URL} /o
RUN sha256sum --check /tmp/p.sha256 && curl -fsSL -o /tmp/p https://example.com/p
