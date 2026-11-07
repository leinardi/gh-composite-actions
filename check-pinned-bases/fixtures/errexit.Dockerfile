# A verification counts only when its failure fails the RUN: Docker's /bin/sh -c has no errexit.
FROM scratch AS plain
RUN curl -fsSL -o /tmp/a https://example.com/a; sha256sum --check /tmp/a.sha256; echo done
RUN curl -fsSL -o /tmp/b https://example.com/b && if false; then sha256sum -c /tmp/b.sha256; fi
RUN curl -fsSL -o /tmp/c https://example.com/c && sha256sum -c /tmp/c.sha256 &
RUN curl -fsSL -o /tmp/d https://example.com/d && ! sha256sum -c /tmp/d.sha256
RUN curl -fsSL -o /tmp/e https://example.com/e && sha256sum -c /tmp/e.sha256 | tee /tmp/e.log
RUN set -o pipefail && curl -fsSL -o /tmp/f https://example.com/f && sha256sum -c /tmp/f.sha256 | tee /tmp/f.log
RUN curl -fsSL -o /tmp/g https://example.com/g && { sha256sum -c /tmp/g.sha256; } ; echo done
RUN set -e; curl -fsSL -o /tmp/h https://example.com/h; sha256sum -c /tmp/h.sha256; echo done
RUN set -e; set +e; curl -fsSL -o /tmp/i https://example.com/i; sha256sum -c /tmp/i.sha256; echo done
RUN curl -fsSL -o /tmp/j https://example.com/j && sha256sum -c /tmp/j.sha256 && tar -xf /tmp/j
RUN curl -fsSL -o /tmp/k https://example.com/k; sha256sum -c /tmp/k.sha256
RUN curl -fsSL -o /tmp/l https://example.com/l && { sha256sum -c /tmp/l.sha256 && echo ok; } && echo done
RUN curl -fsSL -o /tmp/m https://example.com/m && sha256sum -c /tmp/m.sha256 || exit 1; echo done
RUN curl -fsSL -o /tmp/n https://example.com/n && sha256sum -c /tmp/n.sha256 || echo mismatch
RUN curl -fsSL -o /tmp/o https://example.com/o && sh -c 'sha256sum -c /tmp/o.sha256; echo inner'
RUN curl -fsSL -o /tmp/p https://example.com/p && sh -ec 'sha256sum -c /tmp/p.sha256; echo inner'
RUN curl -fsSL -o /tmp/q https://example.com/q && sh -ec 'sha256sum -c /tmp/q.sha256'; echo outer
RUN check() { sha256sum -c "$1"; } && curl -fsSL -o /tmp/r https://example.com/r && check /tmp/r.sha256 && echo ok
RUN check() { sha256sum -c "$1"; } && curl -fsSL -o /tmp/s https://example.com/s && check /tmp/s.sha256; echo done
RUN set -e; curl -fsSL -o /tmp/t https://example.com/t; sha256sum -c /tmp/t.sha256 && echo ok; echo done
RUN curl -fsSL -o /tmp/u https://example.com/u && ( sha256sum -c /tmp/u.sha256 ) && echo ok
RUN curl -fsSL -o /tmp/v https://example.com/v && true || sha256sum -c /tmp/v.sha256

FROM scratch AS strict
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN curl -fsSL -o /tmp/w https://example.com/w; sha256sum -c /tmp/w.sha256; echo done
RUN curl -fsSL -o /tmp/x https://example.com/x; sha256sum -c /tmp/x.sha256 | tee /tmp/x.log; echo done

FROM strict AS inherits
RUN curl -fsSL -o /tmp/y https://example.com/y; sha256sum -c /tmp/y.sha256; echo done

FROM scratch AS reset
RUN curl -fsSL -o /tmp/z https://example.com/z; sha256sum -c /tmp/z.sha256; echo done

FROM scratch AS sh-errexit
SHELL ["/bin/sh", "-ec"]
RUN curl -fsSL -o /tmp/aa https://example.com/aa; sha256sum -c /tmp/aa.sha256; echo done
SHELL ["/bin/sh", "-c"]
RUN curl -fsSL -o /tmp/ab https://example.com/ab; sha256sum -c /tmp/ab.sha256; echo done

# A set -e that may not run, or whose effect is undone or unknown, does not make a check count.
FROM scratch AS uncertain
RUN false && set -e; curl -fsSL -o /tmp/ba https://example.com/ba; sha256sum --check /tmp/ba.sha256; echo done
RUN set -e; { set +e; }; curl -fsSL -o /tmp/bb https://example.com/bb; sha256sum --check /tmp/bb.sha256; echo done
RUN true || set -e; curl -fsSL -o /tmp/bc https://example.com/bc; sha256sum -c /tmp/bc.sha256; echo done
RUN if [ -n "$X" ]; then set -e; fi; curl -fsSL -o /tmp/bd https://example.com/bd; sha256sum -c /tmp/bd.sha256; echo done
RUN set -e; for f in a; do set +e; done; curl -fsSL -o /tmp/be https://example.com/be; sha256sum -c /tmp/be.sha256; echo done
RUN set -e; case "$X" in a) set +e ;; esac; curl -fsSL -o /tmp/bf https://example.com/bf; sha256sum -c /tmp/bf.sha256; echo done
RUN set -e; set +o errexit; curl -fsSL -o /tmp/bg https://example.com/bg; sha256sum -c /tmp/bg.sha256; echo done
RUN set -e; set +eu; curl -fsSL -o /tmp/bh https://example.com/bh; sha256sum -c /tmp/bh.sha256; echo done
RUN set -- -e; curl -fsSL -o /tmp/bi https://example.com/bi; sha256sum -c /tmp/bi.sha256; echo done
RUN echo set -e; curl -fsSL -o /tmp/bj https://example.com/bj; sha256sum -c /tmp/bj.sha256; echo done
RUN bash -c 'set -e'; curl -fsSL -o /tmp/bk https://example.com/bk; sha256sum -c /tmp/bk.sha256; echo done
RUN ( set -e ); curl -fsSL -o /tmp/bl https://example.com/bl; sha256sum -c /tmp/bl.sha256; echo done
RUN set -e | cat; curl -fsSL -o /tmp/bm https://example.com/bm; sha256sum -c /tmp/bm.sha256; echo done
RUN set -e & curl -fsSL -o /tmp/bn https://example.com/bn; sha256sum -c /tmp/bn.sha256; echo done
RUN set -e; . /etc/profile; curl -fsSL -o /tmp/bo https://example.com/bo; sha256sum -c /tmp/bo.sha256; echo done
RUN set -e; eval "$OPTS"; curl -fsSL -o /tmp/bp https://example.com/bp; sha256sum -c /tmp/bp.sha256; echo done
RUN off() { set +e; }; set -e; off; curl -fsSL -o /tmp/bq https://example.com/bq; sha256sum -c /tmp/bq.sha256; echo done
RUN set -e; command set +e; curl -fsSL -o /tmp/br https://example.com/br; sha256sum -c /tmp/br.sha256; echo done
RUN set -euxo pipefail; set +o pipefail; curl -fsSL -o /tmp/bs https://example.com/bs; sha256sum -c /tmp/bs.sha256 | tee /tmp/bs.log; echo done
RUN { false && set -e; }; curl -fsSL -o /tmp/bt https://example.com/bt; sha256sum -c /tmp/bt.sha256; echo done
RUN ! { set -e; true; } && curl -fsSL -o /tmp/bu https://example.com/bu; sha256sum -c /tmp/bu.sha256; echo done
# These keep errexit on, so they pass.
RUN set -euxo pipefail; curl -fsSL -o /tmp/ca https://example.com/ca; sha256sum -c /tmp/ca.sha256 | tee /tmp/ca.log; echo done
RUN set -o errexit -o pipefail; curl -fsSL -o /tmp/cb https://example.com/cb; sha256sum -c /tmp/cb.sha256; echo done
RUN { set -e; }; curl -fsSL -o /tmp/cc https://example.com/cc; sha256sum -c /tmp/cc.sha256; echo done
RUN set -e && curl -fsSL -o /tmp/cd https://example.com/cd; sha256sum -c /tmp/cd.sha256; echo done
