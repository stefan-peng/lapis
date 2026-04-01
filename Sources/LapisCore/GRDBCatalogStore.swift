import Foundation
import GRDB

public final class GRDBCatalogStore: CatalogStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try migrator.migrate(dbQueue)
    }

    public func importAsset(_ importedAsset: ImportedAsset) throws -> AssetImportDisposition {
        try dbQueue.write { db in
            if let existing = try fetchAssetRow(path: importedAsset.sourceURL.path(percentEncoded: false), db: db) {
                return .duplicate(try existing.toAsset(decoder: decoder, db: db))
            }

            let asset = Asset(
                sourcePath: importedAsset.sourceURL.path(percentEncoded: false),
                fileIdentity: importedAsset.fileIdentity,
                fileSize: importedAsset.fileSize,
                modifiedAt: importedAsset.modifiedAt,
                captureDate: importedAsset.captureDate,
                cameraMake: importedAsset.cameraMake,
                cameraModel: importedAsset.cameraModel,
                lensModel: importedAsset.lensModel,
                pixelWidth: importedAsset.pixelWidth,
                pixelHeight: importedAsset.pixelHeight,
                format: importedAsset.format,
                gpsCoordinate: importedAsset.gpsCoordinate,
                previewStatus: importedAsset.previewPath == nil ? .missing : .ready,
                previewPath: importedAsset.previewPath
            )

            try persist(asset: asset, in: db)
            return .imported(asset)
        }
    }

    public func fetchAssets(filter: AssetFilter) throws -> [Asset] {
        try dbQueue.read { db in
            var sql = """
            SELECT assets.* FROM assets
            """
            var arguments: StatementArguments = []
            if filter.albumID != nil {
                sql += " JOIN album_assets ON album_assets.asset_id = assets.id"
            }

            var clauses: [String] = []
            if !filter.searchText.isEmpty {
                clauses.append("(lower(source_path) LIKE ? OR lower(ifnull(camera_make, '')) LIKE ? OR lower(ifnull(camera_model, '')) LIKE ? OR lower(ifnull(lens_model, '')) LIKE ? OR lower(keywords_json) LIKE ?)")
                let value = "%\(filter.searchText.lowercased())%"
                arguments += [value, value, value, value, value]
            }
            if let minimumRating = filter.minimumRating {
                clauses.append("rating >= ?")
                arguments += [minimumRating]
            }
            if filter.flaggedOnly {
                clauses.append("flag = ?")
                arguments += [AssetFlag.picked.rawValue]
            }
            if let keyword = filter.keyword?.lowercased(), !keyword.isEmpty {
                clauses.append("lower(keywords_json) LIKE ?")
                arguments += ["%\(keyword)%"]
            }
            if let cameraContains = filter.cameraContains?.lowercased(), !cameraContains.isEmpty {
                clauses.append("(lower(ifnull(camera_make, '')) LIKE ? OR lower(ifnull(camera_model, '')) LIKE ?)")
                let value = "%\(cameraContains)%"
                arguments += [value, value]
            }
            if let lensContains = filter.lensContains?.lowercased(), !lensContains.isEmpty {
                clauses.append("lower(ifnull(lens_model, '')) LIKE ?")
                arguments += ["%\(lensContains)%"]
            }
            if filter.geotaggedOnly {
                clauses.append("latitude IS NOT NULL AND longitude IS NOT NULL")
            }
            if let capturedAfter = filter.capturedAfter {
                clauses.append("capture_date >= ?")
                arguments += [capturedAfter]
            }
            if let capturedBefore = filter.capturedBefore {
                clauses.append("capture_date <= ?")
                arguments += [capturedBefore]
            }
            if
                let latitude = filter.locationLatitude,
                let longitude = filter.locationLongitude,
                let radiusKilometers = filter.locationRadiusKilometers,
                radiusKilometers > 0
            {
                let latitudeDelta = radiusKilometers / 111.0
                let longitudeScale = max(0.1, cos(latitude * .pi / 180))
                let longitudeDelta = radiusKilometers / (111.0 * longitudeScale)
                clauses.append("latitude BETWEEN ? AND ?")
                arguments += [latitude - latitudeDelta, latitude + latitudeDelta]
                clauses.append("longitude BETWEEN ? AND ?")
                arguments += [longitude - longitudeDelta, longitude + longitudeDelta]
            }
            if let albumID = filter.albumID {
                clauses.append("album_assets.album_id = ?")
                arguments += [albumID.uuidString]
            }

            if !clauses.isEmpty {
                sql += " WHERE " + clauses.joined(separator: " AND ")
            }
            sql += " ORDER BY capture_date DESC NULLS LAST, imported_at DESC"

            let rows = try AssetRow.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.map { try $0.toAsset(decoder: decoder, db: db) }
        }
    }

    public func fetchAsset(id: UUID) throws -> Asset? {
        try dbQueue.read { db in
            guard let row = try AssetRow.fetchOne(db, sql: "SELECT * FROM assets WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return try row.toAsset(decoder: decoder, db: db)
        }
    }

    public func fetchAlbums() throws -> [Album] {
        try dbQueue.read { db in
            try AlbumRow.fetchAll(db, sql: "SELECT * FROM albums ORDER BY created_at, name").map(\.album)
        }
    }

    public func createAlbum(named name: String) throws -> Album {
        let album = Album(name: name)
        try dbQueue.write { db in
            try AlbumRow(album: album).insert(db)
        }
        return album
    }

    public func assignAssets(_ assetIDs: [UUID], to albumID: UUID) throws {
        try dbQueue.write { db in
            for assetID in assetIDs {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO album_assets (album_id, asset_id)
                    VALUES (?, ?)
                    """,
                    arguments: [albumID.uuidString, assetID.uuidString]
                )
            }
        }
    }

    public func updateMetadata(
        assetID: UUID,
        rating: Int?,
        flag: AssetFlag?,
        keywords: [String]?,
        gpsCoordinate: GPSCoordinate?
    ) throws {
        try dbQueue.write { db in
            let current = try requireAssetRow(id: assetID, db: db)
            let resolvedKeywords = try keywords ?? decodeKeywords(from: current.keywordsJSON)
            let resolvedGPS = gpsCoordinate ?? current.gpsCoordinate
            let updated = Asset(
                id: UUID(uuidString: current.id)!,
                sourcePath: current.sourcePath,
                fileIdentity: current.fileIdentity,
                fileSize: current.fileSize,
                modifiedAt: current.modifiedAt,
                importedAt: current.importedAt,
                captureDate: current.captureDate,
                cameraMake: current.cameraMake,
                cameraModel: current.cameraModel,
                lensModel: current.lensModel,
                pixelWidth: current.pixelWidth,
                pixelHeight: current.pixelHeight,
                format: AssetFormat(rawValue: current.format)!,
                gpsCoordinate: resolvedGPS,
                previewStatus: PreviewStatus(rawValue: current.previewStatus)!,
                previewPath: current.previewPath,
                rating: rating ?? current.rating,
                flag: flag ?? AssetFlag(rawValue: current.flag)!,
                keywords: resolvedKeywords,
                albumIDs: try fetchAlbumIDs(assetID: assetID, db: db),
                developSettings: try decodeDevelopSettings(from: current.developSettingsJSON)
            )
            try persist(asset: updated, in: db)
        }
    }

    public func saveDevelopSettings(assetID: UUID, settings: DevelopSettings) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE assets SET develop_settings_json = ? WHERE id = ?",
                arguments: [try String(decoding: encoder.encode(settings), as: UTF8.self), assetID.uuidString]
            )
        }
    }

    public func updatePreview(assetID: UUID, previewPath: String?, status: PreviewStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE assets SET preview_path = ?, preview_status = ? WHERE id = ?",
                arguments: [previewPath, status.rawValue, assetID.uuidString]
            )
        }
    }

    public func geotagAssets(_ matches: [GeotagMatch]) throws -> Int {
        try dbQueue.write { db in
            var applied = 0
            for match in matches {
                guard let coordinate = match.coordinate else { continue }
                try db.execute(
                    sql: """
                    UPDATE assets
                    SET latitude = ?, longitude = ?, altitude = ?
                    WHERE id = ?
                    """,
                    arguments: [coordinate.latitude, coordinate.longitude, coordinate.altitude, match.assetID.uuidString]
                )
                applied += db.changesCount
            }
            return applied
        }
    }

    private func fetchAssetRow(path: String, db: Database) throws -> AssetRow? {
        try AssetRow.fetchOne(db, sql: "SELECT * FROM assets WHERE source_path = ?", arguments: [path])
    }

    private func requireAssetRow(id: UUID, db: Database) throws -> AssetRow {
        guard let row = try AssetRow.fetchOne(db, sql: "SELECT * FROM assets WHERE id = ?", arguments: [id.uuidString]) else {
            throw CatalogError.assetNotFound(id)
        }
        return row
    }

    private func persist(asset: Asset, in db: Database) throws {
        let row = AssetRow(asset: asset, encoder: encoder)
        try row.save(db)
        try db.execute(sql: "DELETE FROM asset_keywords WHERE asset_id = ?", arguments: [asset.id.uuidString])
        for keyword in asset.keywords.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            try db.execute(
                sql: "INSERT INTO asset_keywords (asset_id, keyword) VALUES (?, ?)",
                arguments: [asset.id.uuidString, keyword]
            )
        }
    }

    private func fetchAlbumIDs(assetID: UUID, db: Database) throws -> [UUID] {
        let rows = try Row.fetchAll(db, sql: "SELECT album_id FROM album_assets WHERE asset_id = ?", arguments: [assetID.uuidString])
        return rows.compactMap { row in
            guard let value: String = row["album_id"] else { return nil }
            return UUID(uuidString: value)
        }
    }

    private func decodeKeywords(from json: String) throws -> [String] {
        guard !json.isEmpty else { return [] }
        return try decoder.decode([String].self, from: Data(json.utf8))
    }

    private func decodeDevelopSettings(from json: String) throws -> DevelopSettings {
        guard !json.isEmpty else { return .default }
        return try decoder.decode(DevelopSettings.self, from: Data(json.utf8))
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createCatalog") { db in
            try db.create(table: "assets") { table in
                table.column("id", .text).primaryKey()
                table.column("source_path", .text).notNull().unique(onConflict: .ignore)
                table.column("file_identity", .text).notNull()
                table.column("file_size", .integer).notNull()
                table.column("modified_at", .datetime).notNull()
                table.column("imported_at", .datetime).notNull()
                table.column("capture_date", .datetime)
                table.column("camera_make", .text)
                table.column("camera_model", .text)
                table.column("lens_model", .text)
                table.column("pixel_width", .integer).notNull()
                table.column("pixel_height", .integer).notNull()
                table.column("format", .text).notNull()
                table.column("latitude", .double)
                table.column("longitude", .double)
                table.column("altitude", .double)
                table.column("preview_status", .text).notNull()
                table.column("preview_path", .text)
                table.column("rating", .integer).notNull().defaults(to: 0)
                table.column("flag", .text).notNull().defaults(to: AssetFlag.none.rawValue)
                table.column("keywords_json", .text).notNull().defaults(to: "[]")
                table.column("develop_settings_json", .text).notNull()
            }
            try db.create(table: "asset_keywords") { table in
                table.column("asset_id", .text).notNull().indexed().references("assets", onDelete: .cascade)
                table.column("keyword", .text).notNull().indexed()
                table.primaryKey(["asset_id", "keyword"])
            }
            try db.create(table: "albums") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull().unique()
                table.column("created_at", .datetime).notNull()
            }
            try db.create(table: "album_assets") { table in
                table.column("album_id", .text).notNull().indexed().references("albums", onDelete: .cascade)
                table.column("asset_id", .text).notNull().indexed().references("assets", onDelete: .cascade)
                table.primaryKey(["album_id", "asset_id"])
            }
        }
        migrator.registerMigration("migrateDevelopSettingsSchemaV2") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, develop_settings_json FROM assets")
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()

            for row in rows {
                guard
                    let assetID: String = row["id"],
                    let developSettingsJSON: String = row["develop_settings_json"],
                    !developSettingsJSON.isEmpty
                else {
                    continue
                }

                let settings = try decoder.decode(DevelopSettings.self, from: Data(developSettingsJSON.utf8))
                let normalizedJSON = try String(decoding: encoder.encode(settings), as: UTF8.self)
                if normalizedJSON != developSettingsJSON {
                    try db.execute(
                        sql: "UPDATE assets SET develop_settings_json = ? WHERE id = ?",
                        arguments: [normalizedJSON, assetID]
                    )
                }
            }
        }
        return migrator
    }
}

public enum CatalogError: Error, LocalizedError {
    case assetNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .assetNotFound(id):
            "Missing asset with id \(id.uuidString)"
        }
    }
}

private struct AssetRow: FetchableRecord, PersistableRecord {
    var id: String
    var sourcePath: String
    var fileIdentity: String
    var fileSize: Int64
    var modifiedAt: Date
    var importedAt: Date
    var captureDate: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var format: String
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var previewStatus: String
    var previewPath: String?
    var rating: Int
    var flag: String
    var keywordsJSON: String
    var developSettingsJSON: String

    static let databaseTableName = "assets"

    init(row: Row) throws {
        id = row["id"]
        sourcePath = row["source_path"]
        fileIdentity = row["file_identity"]
        fileSize = row["file_size"]
        modifiedAt = row["modified_at"]
        importedAt = row["imported_at"]
        captureDate = row["capture_date"]
        cameraMake = row["camera_make"]
        cameraModel = row["camera_model"]
        lensModel = row["lens_model"]
        pixelWidth = row["pixel_width"]
        pixelHeight = row["pixel_height"]
        format = row["format"]
        latitude = row["latitude"]
        longitude = row["longitude"]
        altitude = row["altitude"]
        previewStatus = row["preview_status"]
        previewPath = row["preview_path"]
        rating = row["rating"]
        flag = row["flag"]
        keywordsJSON = row["keywords_json"]
        developSettingsJSON = row["develop_settings_json"]
    }

    init(asset: Asset, encoder: JSONEncoder) {
        id = asset.id.uuidString
        sourcePath = asset.sourcePath
        fileIdentity = asset.fileIdentity
        fileSize = asset.fileSize
        modifiedAt = asset.modifiedAt
        importedAt = asset.importedAt
        captureDate = asset.captureDate
        cameraMake = asset.cameraMake
        cameraModel = asset.cameraModel
        lensModel = asset.lensModel
        pixelWidth = asset.pixelWidth
        pixelHeight = asset.pixelHeight
        format = asset.format.rawValue
        latitude = asset.gpsCoordinate?.latitude
        longitude = asset.gpsCoordinate?.longitude
        altitude = asset.gpsCoordinate?.altitude
        previewStatus = asset.previewStatus.rawValue
        previewPath = asset.previewPath
        rating = asset.rating
        flag = asset.flag.rawValue
        keywordsJSON = (try? String(decoding: encoder.encode(asset.keywords), as: UTF8.self)) ?? "[]"
        developSettingsJSON = (try? String(decoding: encoder.encode(asset.developSettings), as: UTF8.self)) ?? "{}"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["source_path"] = sourcePath
        container["file_identity"] = fileIdentity
        container["file_size"] = fileSize
        container["modified_at"] = modifiedAt
        container["imported_at"] = importedAt
        container["capture_date"] = captureDate
        container["camera_make"] = cameraMake
        container["camera_model"] = cameraModel
        container["lens_model"] = lensModel
        container["pixel_width"] = pixelWidth
        container["pixel_height"] = pixelHeight
        container["format"] = format
        container["latitude"] = latitude
        container["longitude"] = longitude
        container["altitude"] = altitude
        container["preview_status"] = previewStatus
        container["preview_path"] = previewPath
        container["rating"] = rating
        container["flag"] = flag
        container["keywords_json"] = keywordsJSON
        container["develop_settings_json"] = developSettingsJSON
    }

    var gpsCoordinate: GPSCoordinate? {
        guard let latitude, let longitude else { return nil }
        return GPSCoordinate(latitude: latitude, longitude: longitude, altitude: altitude)
    }

    func toAsset(decoder: JSONDecoder, db: Database) throws -> Asset {
        let keywordRows = try Row.fetchAll(db, sql: "SELECT keyword FROM asset_keywords WHERE asset_id = ? ORDER BY keyword", arguments: [id])
        let keywords = keywordRows.compactMap { row in row["keyword"] as String? }
        let albumRows = try Row.fetchAll(db, sql: "SELECT album_id FROM album_assets WHERE asset_id = ?", arguments: [id])
        let albumIDs: [UUID] = albumRows.compactMap { row in
            guard let albumID: String = row["album_id"] else { return nil }
            return UUID(uuidString: albumID)
        }
        return Asset(
            id: UUID(uuidString: id)!,
            sourcePath: sourcePath,
            fileIdentity: fileIdentity,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            importedAt: importedAt,
            captureDate: captureDate,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            lensModel: lensModel,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            format: AssetFormat(rawValue: format)!,
            gpsCoordinate: latitude.flatMap { lat in longitude.map { GPSCoordinate(latitude: lat, longitude: $0, altitude: altitude) } },
            previewStatus: PreviewStatus(rawValue: previewStatus) ?? .missing,
            previewPath: previewPath,
            rating: rating,
            flag: AssetFlag(rawValue: flag) ?? .none,
            keywords: keywords,
            albumIDs: albumIDs,
            developSettings: try decoder.decode(DevelopSettings.self, from: Data(developSettingsJSON.utf8))
        )
    }
}

private struct AlbumRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "albums"

    var id: String
    var name: String
    var createdAt: Date

    init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        createdAt = row["created_at"]
    }

    init(album: Album) {
        id = album.id.uuidString
        name = album.name
        createdAt = album.createdAt
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["created_at"] = createdAt
    }

    var album: Album {
        Album(id: UUID(uuidString: id)!, name: name, createdAt: createdAt)
    }
}
