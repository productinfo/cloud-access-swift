//
//  WebDAVCredential.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct WebDAVCredential {
	public let baseURL: URL
	public let username: String
	public let password: String
	public let allowedCertificate: Data?
}
