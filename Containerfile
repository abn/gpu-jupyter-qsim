ARG CUDA=11.7.1
ARG UBUNTU=22.04
ARG BASE=runtime
ARG HUB=3.0.0

FROM docker.io/jupyter/base-notebook:hub-${HUB} AS base-notebook


FROM docker.io/nvidia/cuda:${CUDA}-cudnn8-devel-ubuntu${UBUNTU} AS build

ARG CONDA_DIR=/opt/conda
ARG QSIM_COMMIT=0041775799e1c10ee2f96d6e81bc4664bc77b3a4
ARG QSIM_DIR=/opt/qsim

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential \
        cmake \
        git \
        wget \
        curl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir ${QSIM_DIR} \
    && curl -sS -L \
        https://api.github.com/repos/quantumlib/qsim/tarball/${QSIM_COMMIT} \
        | tar -xz --strip-components=1 -C ${QSIM_DIR}

ENV PATH="${CONDA_DIR}/bin:${PATH}"

COPY --from=base-notebook ${CONDA_DIR} ${CONDA_DIR}

RUN pip install \
      cirq \
      cirq[contrib] \
      qsimcirq

RUN conda install -y -c conda-forge \
      openmm \
      cudatoolkit

RUN conda clean -afy \
    && find ${CONDA_DIR} -follow -type f -name '*.a' -delete \
    && find ${CONDA_DIR} -follow -type f -name '*.pyc' -delete \
    && find ${CONDA_DIR} -follow -type f -name '*.js.map' -delete


FROM docker.io/nvidia/cuda:${CUDA}-cudnn8-${BASE}-ubuntu${UBUNTU}

ARG CONDA_DIR=/opt/conda
ARG QSIM_DIR=/opt/qsim

ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="100"

USER 0

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Configure environment
ENV CONDA_DIR=${CONDA_DIR} \
    QSIM_DIR=${QSIM_DIR} \
    SHELL=/bin/bash \
    NB_USER="${NB_USER}" \
    NB_UID=${NB_UID} \
    NB_GID=${NB_GID} \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    TF_FORCE_UNIFIED_MEMORY=1 \
    XLA_PYTHON_CLIENT_MEM_FRACTION=2.0

ENV PATH="${CONDA_DIR}/bin:${PATH}"
ENV HOME="/home/${NB_USER}"

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

RUN apt-get update --yes \
    && apt-get upgrade --yes \
    && apt-get install --yes --no-install-recommends \
        # jupyter base
        bzip2 \
        ca-certificates \
        fonts-liberation \
        locales \
        pandoc \
        run-one \
        sudo \
        tini \
        wget \
        # extras
        curl \
        git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && locale-gen

COPY --from=base-notebook /usr/local/bin /usr/local/bin
COPY --from=base-notebook /etc/jupyter /etc/jupyter
COPY --from=base-notebook /etc/pam.d/su /etc/pam.d/su
COPY --from=base-notebook /etc/sudoers /etc/sudoers
COPY --from=base-notebook /etc/skel/.bashrc /etc/skel/.bashrc

COPY --chown="${NB_UID}:${NB_GID}" --from=base-notebook /home/${NB_USER} /home/${NB_USER}

COPY --chown="${NB_UID}:${NB_GID}" --from=build ${CONDA_DIR} ${CONDA_DIR}
COPY --chown="${NB_UID}:${NB_GID}" --from=build ${QSIM_DIR} ${QSIM_DIR}

# install additional packages
RUN pip install \
    ipyfilechooser \
    jupyter_http_over_ws

RUN useradd -l -M -s /bin/bash -N -u "${NB_UID}" "${NB_USER}" \
    && chmod g+w /etc/passwd \
    && fix-permissions "${HOME}" \
    && fix-permissions "${CONDA_DIR}" \
    && fix-permissions "${QSIM_DIR}" \
    && fix-permissions /etc/jupyter

# Add SETUID bit to the ldconfig binary so that non-root users can run it.
RUN chmod u+s /sbin/ldconfig{,.real}

USER ${NB_UID}
WORKDIR "${HOME}"

EXPOSE 8888

# Configure container startup
ENTRYPOINT ["tini", "-g", "--"]
CMD ["start-notebook.sh"]

# HEALTHCHECK documentation: https://docs.docker.com/engine/reference/builder/#healthcheck
# This healtcheck works well for `lab`, `notebook`, `nbclassic`, `server` and `retro` jupyter commands
# https://github.com/jupyter/docker-stacks/issues/915#issuecomment-1068528799
HEALTHCHECK  --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -O- --no-verbose --tries=1 --no-check-certificate \
    http${GEN_CERT:+s}://localhost:8888${JUPYTERHUB_SERVICE_PREFIX:-/}api || exit 1
