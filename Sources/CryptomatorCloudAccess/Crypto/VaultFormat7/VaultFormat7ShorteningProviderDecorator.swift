//
//  VaultFormat7ShorteningProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public enum VaultFormat7ShorteningError: Error {
	case c9sItemNotFound
}

private extension CloudPath {
	func appendingNameFileComponent() -> CloudPath {
		return appendingPathComponent("name.c9s")
	}

	func appendingContentsFileComponent() -> CloudPath {
		return appendingPathComponent("contents.c9r")
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 7 (only name shortening).

 With this decorator, it is expected that the cloud provider methods are being called with ciphertext paths. It transparently deflates/inflates filenames according to vault format 7, see the name shortening section at the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/#name-shortening).

 It's meaningless to use this shortening decorator without being decorated by an instance of `VaultFormat7ProviderDecorator` (crypto decorator). This shortening decorator explicitly only shortens the fourth path component relative to `vaultPath`.
 */
public class VaultFormat7ShorteningProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let shortenedNameCache: VaultFormat7ShortenedNameCache
	let tmpDirURL: URL

	public init(delegate: CloudProvider, vaultPath: CloudPath) throws {
		self.delegate = delegate
		self.shortenedNameCache = try VaultFormat7ShortenedNameCache(vaultPath: vaultPath)
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToC9S {
			return delegate.fetchItemMetadata(at: shortened.cloudPath).then { shortenedMetadata in
				return self.getOriginalMetadata(shortenedMetadata)
			}
		} else {
			return delegate.fetchItemMetadata(at: shortened.cloudPath)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		return delegate.fetchItemList(forFolderAt: shortened.cloudPath, withPageToken: pageToken).then { itemList -> Promise<CloudItemList> in
			let originalItemPromises = itemList.items.map { self.getOriginalMetadata($0) }
			return any(originalItemPromises).then { maybeOriginalItems -> CloudItemList in
				let originalItems = maybeOriginalItems.filter { $0.value != nil }.map { $0.value! }
				return CloudItemList(items: originalItems, nextPageToken: itemList.nextPageToken)
			}
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToC9S {
			let contentsFilePath = shortened.cloudPath.appendingContentsFileComponent()
			return delegate.downloadFile(from: contentsFilePath, to: localURL)
		} else {
			return delegate.downloadFile(from: shortened.cloudPath, to: localURL)
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
			return createC9SFolderAndUploadNameFile(c9sDir).then { () -> Promise<CloudItemMetadata> in
				let contentsFilePath = shortened.cloudPath.appendingContentsFileComponent()
				return self.delegate.uploadFile(from: localURL, to: contentsFilePath, replaceExisting: replaceExisting)
			}.then { _ in
				return self.delegate.fetchItemMetadata(at: shortened.cloudPath)
			}.then { shortenedMetadata in
				return self.getOriginalMetadata(shortenedMetadata)
			}
		} else {
			return delegate.uploadFile(from: localURL, to: shortened.cloudPath, replaceExisting: replaceExisting)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
			return createC9SFolderAndUploadNameFile(c9sDir)
		} else {
			return delegate.createFolder(at: shortened.cloudPath)
		}
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		if shortened.pointsToC9S {
			return delegate.deleteFolder(at: shortened.cloudPath)
		} else {
			return delegate.deleteFile(at: shortened.cloudPath)
		}
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		let shortened = shortenedNameCache.getShortenedPath(cloudPath)
		return delegate.deleteFolder(at: shortened.cloudPath)
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)

		enum PathState { case shortened, unshortened }
		let oldState: PathState = shortenedSource.pointsToC9S ? .shortened : .unshortened
		let newState: PathState = shortenedTarget.pointsToC9S ? .shortened : .unshortened

		switch (oldState, newState) {
		case (.unshortened, .unshortened):
			return delegate.moveFile(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
		case (.unshortened, .shortened):
			return createC9SFolderAndUploadNameFile(shortenedTarget.c9sDir!).then {
				return self.delegate.moveFile(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath.appendingContentsFileComponent())
			}
		case (.shortened, .unshortened):
			return delegate.moveFile(from: shortenedSource.cloudPath.appendingContentsFileComponent(), to: shortenedTarget.cloudPath).then {
				return self.delegate.deleteFolder(at: shortenedSource.cloudPath)
			}
		case (.shortened, .shortened):
			return delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath).then {
				return self.uploadNameFile(shortenedTarget.c9sDir!)
			}
		}
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		let shortenedSource = shortenedNameCache.getShortenedPath(sourceCloudPath)
		let shortenedTarget = shortenedNameCache.getShortenedPath(targetCloudPath)

		enum PathState { case shortened, unshortened }
		let oldState: PathState = shortenedSource.pointsToC9S ? .shortened : .unshortened
		let newState: PathState = shortenedTarget.pointsToC9S ? .shortened : .unshortened

		switch (oldState, newState) {
		case (.unshortened, .unshortened):
			return delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath)
		case (.unshortened, .shortened):
			return delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath).then {
				return self.uploadNameFile(shortenedTarget.c9sDir!)
			}
		case (.shortened, .unshortened):
			return delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath).then {
				return self.delegate.deleteFile(at: shortenedTarget.cloudPath.appendingNameFileComponent())
			}
		case (.shortened, .shortened):
			return delegate.moveFolder(from: shortenedSource.cloudPath, to: shortenedTarget.cloudPath).then {
				return self.uploadNameFile(shortenedTarget.c9sDir!)
			}
		}
	}

	// MARK: - Internal

	private func getOriginalMetadata(_ shortenedMetadata: CloudItemMetadata) -> Promise<CloudItemMetadata> {
		return shortenedNameCache.getOriginalPath(shortenedMetadata.cloudPath, nameC9SLoader: downloadNameFile).then { originalPath in
			let shortened = self.shortenedNameCache.getShortenedPath(originalPath)
			if shortened.pointsToC9S, let c9sDir = shortened.c9sDir {
				return self.fetchC9SItemMetadata(c9sDir).then { c9sItemMetadata -> CloudItemMetadata in
					let originalItemType = self.guessItemTypeByC9SItemName(c9sItemMetadata.name)
					let originalLastModifiedDate = originalItemType == .folder ? shortenedMetadata.lastModifiedDate : c9sItemMetadata.lastModifiedDate
					let originalSize = originalItemType == .folder ? shortenedMetadata.size : c9sItemMetadata.size
					return CloudItemMetadata(name: c9sDir.originalName, cloudPath: originalPath, itemType: originalItemType, lastModifiedDate: originalLastModifiedDate, size: originalSize)
				}
			} else {
				return Promise(CloudItemMetadata(name: shortenedMetadata.name, cloudPath: originalPath, itemType: shortenedMetadata.itemType, lastModifiedDate: shortenedMetadata.lastModifiedDate, size: shortenedMetadata.size))
			}
		}
	}

	private func downloadNameFile(_ c9sDirPath: CloudPath) -> Promise<Data> {
		let nameFileCloudPath = c9sDirPath.appendingNameFileComponent()
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: nameFileCloudPath, to: localNameFileURL).then {
			return try Data(contentsOf: localNameFileURL)
		}.always {
			try? FileManager.default.removeItem(at: localNameFileURL)
		}
	}

	private func fetchC9SItemMetadata(_ c9sDir: C9SDir) -> Promise<CloudItemMetadata> {
		return delegate.fetchItemList(forFolderAt: c9sDir.cloudPath, withPageToken: nil).then { c9sItemList -> CloudItemMetadata in
			let wanted = ["contents.c9r", "dir.c9r", "symlink.c9r"]
			let filter = { (item: CloudItemMetadata) in wanted.contains(item.name) }
			guard let c9sItemMetadata = c9sItemList.items.first(where: filter) else {
				throw VaultFormat7ShorteningError.c9sItemNotFound
			}
			return c9sItemMetadata
		}
	}

	private func guessItemTypeByC9SItemName(_ c9sItemName: String) -> CloudItemType {
		switch c9sItemName {
		case "contents.c9r":
			return .file
		case "dir.c9r":
			return .folder
		case "symlink.c9r":
			return .symlink
		default:
			return .unknown
		}
	}

	private func createC9SFolderAndUploadNameFile(_ c9sDir: C9SDir) -> Promise<Void> {
		return delegate.createFolder(at: c9sDir.cloudPath).then {
			return self.uploadNameFile(c9sDir)
		}
	}

	private func uploadNameFile(_ c9sDir: C9SDir) -> Promise<Void> {
		let localNameFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		do {
			try c9sDir.originalName.write(to: localNameFileURL, atomically: true, encoding: .utf8)
		} catch {
			return Promise(error)
		}
		let nameFileCloudPath = c9sDir.cloudPath.appendingNameFileComponent()
		return delegate.uploadFile(from: localNameFileURL, to: nameFileCloudPath, replaceExisting: true).then { _ in () }
	}
}
