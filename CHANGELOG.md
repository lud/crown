# Changelog

All notable changes to this project will be documented in this file.

## [0.3.2] - 2026-08-07

### 📚 Documentation

- Add documentation to public API (_lud_)

### 🧪 Testing

- Tighten tests around oban peer (_lud_)

### ⚙️ Miscellaneous Tasks

- Setup versioning (_lud_)
- Fix CI Oban DB migrations (_lud_)

## [0.3.1] - 2026-06-10

### 🧪 Testing

- Updated Oban to simplify peer mocking (_lud_)

### ⚙️ Miscellaneous Tasks

- Dump epmd state on test suite start (_lud_)
- Fix test helper on fresh booted machine (_Ludovic Dem_)
- Default to log_level=info for OTP/monitor events (_lud_)

## [0.3.0] - 2026-05-04

### 🚀 Features

- Added new ObanPeer oracle (_lud_)
- Added telemetry events and default logger (_lud_)
- Forward handle_info for message based oracles (_lud_)

### 📚 Documentation

- Added basic README.md documentation (_lud_)

### ⚙️ Miscellaneous Tasks

- Configure postgres service in CI (_lud_)
- Refactored oban peer mocked tests (_lud_)

## [0.2.1] - 2026-03-21

### ⚙️ Miscellaneous Tasks

- Added postgresql container for tests in CI (_lud_)

## [0.2.0] - 2026-03-20

### 🚀 Features

- Added simple Postgres lease-based oracle (_lud_)

### ⚙️ Miscellaneous Tasks

- Allow Elixir 1.18 (_lud_)
- Removed dead code (_lud_)
- Formatting the library with Quokka (_lud_)

## [0.1.1] - 2026-03-09

### 🚀 Features

- Initial prototype (_lud_)
- Added simple demo script (_lud_)

### ⚙️ Miscellaneous Tasks

- Initialize libcheck and docs (_lud_)

