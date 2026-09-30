# TODO

## MUST TODO

- test everything
  - test error behavior

- Review with frontier AI

- Review dev env, lint, tests, related docs, etc
  - /usr/lib/qt6/bin/qmlformat
  - /usr/lib/qt6/bin/qmltestrunner

- Review logs output for errors

## Look-n-feel needs to be made nicer

## NEXT FEATURES

- Config
  - configure which fields are displayed
  - automatically bring the tunnel back up when it is taken down outside the plugin
    - the hook point is the "external" verdict in Service._applyStatus, next to
      the latch the drop notification already uses
    - needs a backoff: wg-quick up failing on an unreachable endpoint would
      otherwise turn into a restart loop, one notification per attempt

- Omarchy toggle

- Support other interfaces/config files
