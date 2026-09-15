# Overlay provenance

This directory is a deliberately small Apereo CAS WAR Overlay, not a checkout of
the CAS framework source repository.

- CAS server artifact: `org.apereo.cas:*:8.0.1`
- Overlay baseline: Apereo `cas-overlay-template`, release tag
  `20260817123643` (`5e5db5271bcd9df56ea332acec2f9e212e4797cd`)
- Java baseline: 25
- Gradle Wrapper: 9.6.1
- Spring Boot: 4.1.0

The template release body says `CAS: 8.0.1`, but its generated
`gradle.properties` contained the moving `8.1.0-SNAPSHOT` value. Per the
template's own patch-release guidance, this POC pins both `version` and
`cas.version` to `8.0.1`; the remaining Java, Gradle and Spring Boot values match
the official CAS Initializr 8.0 line metadata checked on 2026-09-15.

The only added CAS module is the officially documented
`cas-server-support-json-service-registry`, used for the explicit local test
service registration.

The template's `jvmVendor` is left blank because its own Dockerfile already uses
an Azul Zulu JDK 25 base image. Zulu is explicitly within CAS's supported JDK
distributions; this avoids downloading an otherwise redundant Corretto JDK
during every clean container build. BuildKit also persists the Gradle download
cache across retries.
