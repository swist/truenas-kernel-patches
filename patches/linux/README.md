# Source patches

Nothing is needed today: every TrueNAS kernel line from 6.6 onwards already
contains the BE200 (`8086:272b`) iwlwifi support. TrueNAS only disables it in
`scripts/package/truenas/truenas.config`, which `config/wifi.config` overrides.

If a future driver fix needs backporting (e.g. a newer firmware API for the
BE200), drop `git format-patch` output here:

- `common/NNNN-*.patch`: applied to every kernel
- `<major>.<minor>/NNNN-*.patch` (e.g. `6.12/`): applied only to that kernel line

`scripts/build.sh` applies them in name order and fails loudly if one no longer
applies; the CI build then opens an issue so you can rebase it.
