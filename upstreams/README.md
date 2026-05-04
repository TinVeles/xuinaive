# Upstreams

This directory is the local upstream workspace used by `unified-proxy-manager`.

Expected layout after running `../prepare-upstreams.sh`:

```text
upstreams/
├── x-ui-pro/
│   └── x-ui-pro.sh
└── NH-Panel-Naive-Hy2/
    └── install.sh
```

The upstream projects are intentionally not committed into this repository. Fetch them on the VPS:

```bash
cd unified-proxy-manager
bash prepare-upstreams.sh
```
