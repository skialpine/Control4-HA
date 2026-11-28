# Spec Delta

## Purpose

Let Control4 users discover, route and control supported Home Assistant media players with reliable playback feedback.

## ADDED Requirements

### Requirement: Native media transport and routing
Media Player SHALL offer the supported transport, volume and playback settings on its qualified Control4 media surfaces. It SHALL preserve qualified room and AV routing and show confirmed playback state and metadata. Source selection and browsing SHALL be offered where supported by both the Home Assistant player and Control4.

#### Scenario: Two players have different playback capabilities
- **WHEN** a room selects a player that supports playback and volume but lacks source selection
- **THEN** Control4 offers supported controls for that player and sends its actions only to the selected endpoint

### Requirement: Artwork respects authentication boundaries
Media Player SHALL preserve playback and metadata if artwork is unavailable. Artwork displayed in Control4 MUST use a verified retrieval path that keeps Home Assistant credentials and signed provider URLs out of user-visible metadata and shared logs.

#### Scenario: An artwork URL includes private credentials
- **WHEN** Home Assistant reports track metadata with an artwork URL that lacks a qualified retrieval path
- **THEN** Control4 displays the supported metadata and omits the unverified artwork URL
