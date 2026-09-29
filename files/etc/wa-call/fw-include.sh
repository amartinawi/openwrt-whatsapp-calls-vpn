#!/bin/sh
# SPDX-License-Identifier: MIT
# fw3 include: re-apply rules after every firewall start/reload (GL reloads the firewall often).
[ -x /etc/wa-call/wa-call.sh ] && /etc/wa-call/wa-call.sh apply
exit 0
