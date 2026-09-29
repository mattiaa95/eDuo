//
//  Constants.swift
//  eDuo
//
//  Shared constants for the Settings module.
//
//  These used to point at iGBA's WordPress site, on a "one support hub for the
//  family of apps" rationale. That does not survive App Review: the privacy
//  policy a reviewer opens has to describe *this* app, and eDuo's profile is
//  genuinely different — it asks for the microphone, and it has no ads and no
//  tracking at all, none of which iGBA's policy says.
//
//  eDuo now has its own pages, served from a static site with no analytics and
//  no third-party requests (source: the eDuo-site folder alongside this repo).
//

import Foundation

enum INDSConstants {
    /// mattials.com: one support page and one policy for iGBA, eDuo and eNES.
    static let supportURL = URL(string: "https://mattials.com/support/")!
    static let privacyPolicyURL = URL(string: "https://mattials.com/privacy/")!
    static let termsURL = URL(string: "https://mattials.com/terms/")!
    static let sourceCodeURL = URL(string: "https://github.com/mattiaa95/eDuo")!
    static let melonDSURL = URL(string: "https://github.com/melonDS-emu/melonDS")!
}
