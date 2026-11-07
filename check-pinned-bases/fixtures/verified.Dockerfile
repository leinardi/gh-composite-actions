# Downloads that are verified after they happen, through the same wrappers: all pass.
FROM scratch AS fetch
ARG FILE_SHA256=0000000000000000000000000000000000000000000000000000000000000000
RUN timeout 60 curl -fsSL -o /tmp/a https://example.com/a \
	&& echo "${FILE_SHA256}  /tmp/a" | sha256sum --check --strict - || exit 1
RUN sh -c 'curl -fsSL -o /tmp/b https://example.com/b && echo "$0  /tmp/b" | sha256sum -c -' "${FILE_SHA256}"
RUN curl -fsSL -o /tmp/c https://example.com/c \
	&& sh -c "echo '${FILE_SHA256}  /tmp/c' | sha256sum -c -"
ADD --checksum=sha256:${FILE_SHA256} https://example.com/d /d
COPY <<EOT /install.sh
#!/bin/sh
set -eu
curl -fsSL -o /tmp/e https://example.com/e
echo "0000000000000000000000000000000000000000000000000000000000000000  /tmp/e" | sha256sum -c -
EOT
COPY <<EOT /notes.txt
Install curl with apt-get install curl.
EOT
