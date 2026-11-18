# Release readiness

Use this checklist for one immutable release candidate. Record the suite tag,
archive SHA-256 values, Home Assistant version, and companion tag and commit.
Attach evidence to each completed item. Recheck affected items if any artifact
changes.

## First feedback release

- [ ] Qualify Coordinator, Light and Switch against the original and prototype
  drivers. Include clean setup, supported in-place upgrades, explicit Switch
  migration, and restoration of the prior project. Record the result of each
  predecessor task. [First-demo qualification](first-demo-packages.md)
- [ ] Verify help and physical controls in the actual Composer and Navigator
  panes. Record what was checked in a simulator, on Director, and on physical
  hardware. Include the independent usability review and the installer’s native
  observations.
- [ ] Record timings for common operations with and without the optional
  companion. Separate Home Assistant service acceptance, reported state and
  physical observations. [Performance contract](performance-contract.md)
- [ ] Verify the three archives, install guide and rollback instructions. Run
  the provenance check before distributing the candidate. Label the packages as
  feedback builds and list the device families they support.

## General availability

- [ ] Pass the feedback checklist and run the release source and test audit.
  Recheck fixes and resolve all Critical, High and Medium findings in scope.
- [ ] Demonstrate clean installation, restart and reconnect, scene persistence,
  and Composer-free suite update and recovery on the approved Director.
- [ ] Publish the supported Home Assistant and companion version pair and
  confirm the suite works with the companion absent. Exercise an unsupported
  companion version and verify the installer can identify the issue.
- [ ] Complete the installation, troubleshooting, upgrade and rollback manuals
  and verify the portable setup skill against the published versions.
- [ ] Attach the accepted Marketplace listing, the qualified companion release
  and the clean catalog installation receipt described below. A pending listing
  keeps general availability open. Feedback release eligibility follows the
  separate checklist above.

## HA Gesture Bridge publication handoff

Track these steps in a separate HA Gesture Bridge change. The integration keeps
the `ha_gesture_bridge` domain and its own release version. The C4 release
record links to the HA change and its evidence.

1. **Validate the candidate.** Record the exact tag and commit, package digest,
   minimum and tested current Home Assistant versions, and supported catalog,
   preparation and gesture contracts. Run the catalog and Home Assistant
   integration validators required at submission time. Attach their results.
   Review the integration and repository metadata, branding, installation and
   support documentation, and upgrade notes.
1. **Qualify the HA release.** In an isolated lab, install the candidate and
   upgrade from the supported previous version. Exercise device discovery,
   gestures and indicators with the referenced C4 candidate. Publish the tested
   artifact and record its tag and digest.
1. **Confirm catalog acceptance.** Record the accepted listing and the version
   offered there. Track submission, acceptance and installation as separate
   evidence.
   [Home Assistant Marketplace](https://www.home-assistant.io/integrations/marketplace/)
1. **Install from the listing.** Start with a clean Home Assistant instance.
   Find HA Gesture Bridge in Marketplace search, install it from the catalog,
   restart Home Assistant, and verify the loaded version and its pairing with
   the C4 candidate. Record the listing, installed version, Home Assistant
   version, and setup and control outcomes. Keep pilot repository-link runs as
   separate evidence. If the catalog delivers a different version, qualify that
   version or correct the listing before general availability.
