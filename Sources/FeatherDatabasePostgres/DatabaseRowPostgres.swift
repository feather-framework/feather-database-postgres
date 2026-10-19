//
//  DatabaseRowPostgres.swift
//  feather-database-postgres
//
//  Created by Tibor Bödecs on 2026. 01. 10.
//

public import FeatherDatabase
import PostgresNIO

public struct DatabaseRowPostgres: DatabaseRow {

    var row: PostgresRow
    private let randomAccessRow: PostgresRandomAccessRow

    init(row: PostgresRow) {
        self.row = row
        self.randomAccessRow = row.makeRandomAccess()
    }

    public var columns: [String] {
        randomAccessRow.map(\.columnName)
    }

    public func contains(column: String) -> Bool {
        randomAccessRow.contains(column)
    }

    public func decodeNil(column: String) throws(DecodingError) -> Bool {
        guard randomAccessRow.contains(column) else {
            throw .keyNotFound(
                PostgresColumnKey(stringValue: column),
                .init(
                    codingPath: [],
                    debugDescription: "Missing data for column \(column)."
                )
            )
        }
        return randomAccessRow[column].bytes == nil
    }

    /// Decode a column value as the given type.
    ///
    /// This uses Postgres decoding rules for `Decodable` types.
    /// - Parameters:
    ///   - column: The column name to decode.
    ///   - type: The expected type to decode as.
    /// - Throws: A `DecodingError` if the value cannot be decoded.
    /// - Returns: The decoded value.
    public func decode<T: Decodable>(
        column: String,
        as type: T.Type
    ) throws(DecodingError) -> T {
        let row = randomAccessRow
        guard row.contains(column) else {
            throw .dataCorrupted(
                .init(
                    codingPath: [],
                    debugDescription: "Missing data for column \(column)."
                )
            )
        }
        let cell = row[column]
        if let type = type as? any PostgresDecodable.Type {
            do {
                guard let value = try cell.decode(type, context: .default) as? T
                else {
                    throw DecodingError.typeMismatch(
                        T.self,
                        .init(
                            codingPath: [],
                            debugDescription:
                                "Could not convert data to \(T.self)."
                        )
                    )
                }
                return value
            }
            catch {
                throw DecodingError.typeMismatch(
                    T.self,
                    .init(
                        codingPath: [],
                        debugDescription: "\(error)"
                    )
                )
            }
        }

        throw DecodingError.typeMismatch(
            T.self,
            .init(
                codingPath: [],
                debugDescription: "Data is not convertible to \(type)."
            )
        )
    }
}

private struct PostgresColumnKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
