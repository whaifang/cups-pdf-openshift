### Compile Stage
FROM quay.io/centos/centos:stream8

RUN dnf -y install gcc cups cups-libs cups-devel ghostscript glibc

# Create user for compiling under it
RUN useradd cups

# Copy source
COPY docker/src/cups-pdf /home/cups/

WORKDIR /home/cups/src

# Compiling
# Creates /home/cups/src/cups-pdf executable
RUN gcc -O9 -s cups-pdf.c -o cups-pdf -lcups



### Run Stage
FROM registry.redhat.io/ubi8/ubi:8.6
#FROM redhat/ubi8:8.6

ENV NAME="rhel8/cups"
ENV VERSION="2.2.6"
ENV SUMMARY="CUPS printing system"
ENV DESCRIPTION="CUPS printing system provides a portable printing layer for \
                 UNIX® operating systems. It has been developed by Apple Inc. \
                 to promote a standard printing solution for all UNIX vendors and users. \
                 CUPS provides the System V and Berkeley command-line interfaces."

LABEL name="$NAME"
LABEL version="$VERSION"
LABEL summary="$SUMMARY"
LABEL description="$DESCRIPTION"
LABEL usage="podman run -d --name cups -p 6631:6631 $NAME"

LABEL com.redhat.component="cups-container"
LABEL io.k8s.description="$DESCRIPTION"
LABEL io.k8s.display-name="cups $VERSION"
LABEL io.openshift.expose-services="6631:cups"
LABEL io.openshift.tags="cups"

RUN dnf install -y cups  && dnf clean all && \
	mkdir -p /opt/cups

# Copy cups-pdf files
COPY --from=0 /home/cups/src/cups-pdf /usr/lib/cups/backend/cups-pdf
COPY --from=0 /home/cups/extra/CUPS-PDF_noopt.ppd /etc/cups/ppd/
COPY docker/src/cups-pdf.conf /etc/cups/
COPY docker/src/cups-files.conf /etc/cups/
COPY docker/src/cupsd.conf /etc/cups/

# we do not need to ship cups-brf backend and it works only under root user anyway
RUN rm -f /usr/lib/cups/backend/cups-brf

# Set environment variables with all used paths
ENV CUPS_CONF=/etc/cups
ENV CUPS_LOGS=/var/log/cups
ENV CUPS_SPOOL=/var/spool/cups
ENV CUPS_PDF_SPOOL=/var/spool/cups-pdf/SPOOL
ENV CUPS_CACHE=/var/cache/cups
ENV CUPS_RUN=/var/run/cups
ENV CUPS_LIB=/usr/lib/cups
ENV CUPS_PDF_OUT=/mnt

# Copy the entrypoint script
COPY docker/src/entrypoint.sh /opt/cups/entrypoint.sh

# Setup cache before first run
RUN mkdir -p ${CUPS_CACHE} && \
    mkdir -p ${CUPS_PDF_OUT} && \
    mkdir -p ${CUPS_PDF_SPOOL}

# Set group ownership and permissions to enable the arbitrary
# user, that got assigned by Openshift (who has the GID 0) to
# use the provided paths. Make entrypoint script executable
RUN chgrp -R 0 ${CUPS_CONF} && chmod -R g=u ${CUPS_CONF} && \
	chgrp -R 0 ${CUPS_LOGS} && chmod -R g=u ${CUPS_LOGS} && \
	chgrp -R 0 ${CUPS_SPOOL} && chmod -R g=u ${CUPS_SPOOL} && \
	chgrp -R 0 ${CUPS_PDF_SPOOL} && chmod -R g=u ${CUPS_PDF_SPOOL} && \
	chgrp -R 0 ${CUPS_CACHE} && chmod -R g=u ${CUPS_CACHE} && \
	chgrp -R 0 ${CUPS_RUN} && chmod -R g=u ${CUPS_RUN} && \
	chgrp -R 0 ${CUPS_LIB} && chmod -R g=u ${CUPS_LIB} && \
	chgrp -R 0 ${CUPS_PDF_OUT} && chmod -R g=u ${CUPS_PDF_OUT} && \
	chgrp -R 0 /opt/cups && chmod -R g=u /opt/cups && \
    chmod +x /opt/cups/entrypoint.sh

# Setting UID and GID
# Only used by Container environments, which don't force
# arbitrary UIDs
USER 1000:0

# Port to communicate with CUPS
EXPOSE 6631

# Name of the first CUPS-PDF instance
# provide more instance names here, if you need more than one
# CUPS-PDF printer inside this CUPS container
ENV CUPS_PDF_INSTANCE1=cups-pdf


ENTRYPOINT /opt/cups/entrypoint.sh
