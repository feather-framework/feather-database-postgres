//
//  FeatherDatabasePostgresTestSuite.swift
//  feather-database-postgres
//
//  Created by Tibor Bödecs on 2026. 01. 10..
//

import FeatherDatabase
import Logging
import NIOSSL
import PostgresNIO
import Testing

@testable import FeatherDatabasePostgres

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite
struct FeatherDatabasePostgresTestSuite {

    private func randomTableSuffix() -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var suffix = ""
        suffix.reserveCapacity(16)
        for _ in 0..<16 {
            suffix.append(characters.randomElement() ?? "a")
        }
        return suffix
    }

    private func runUsingTestDatabaseClient(
        _ closure:
            @escaping (@Sendable (DatabaseClientPostgres) async throws -> Void)
    ) async throws {
        var logger = Logger(label: "test")
        logger.logLevel = .info

        let environment = ProcessInfo.processInfo.environment

        let finalCertPath =
            environment["POSTGRES_CA_CERT_PATH"]
            ?? URL(
                fileURLWithPath: #filePath
            )
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docker")
            .appendingPathComponent("postgres")
            .appendingPathComponent("certificates")
            .appendingPathComponent("ca.pem")
            .path()

        let host = environment["POSTGRES_HOST"] ?? "127.0.0.1"
        let port = environment["POSTGRES_PORT"].flatMap(Int.init) ?? 5432

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        let rootCert = try NIOSSLCertificate.fromPEMFile(finalCertPath)
        tlsConfig.trustRoots = .certificates(rootCert)
        tlsConfig.certificateVerification = .fullVerification

        let client = PostgresClient(
            configuration: .init(
                host: host,
                port: port,
                username: "postgres",
                password: "postgres",
                database: "postgres",
                tls: .require(tlsConfig)
            ),
            backgroundLogger: logger
        )

        let database = DatabaseClientPostgres(
            client: client,
            logger: logger
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await client.run()
            }
            group.addTask {
                try await closure(database)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: -

    @Test
    func foreignKeySupport() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let planetsTable = "planets_\(suffix)"
            let moonsTable = "moons_\(suffix)"

            try await database.withTransaction { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: moonsTable)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: planetsTable)" CASCADE;
                        """#
                )

                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: planetsTable)" (
                            "id" INTEGER PRIMARY KEY,
                            "name" TEXT NOT NULL
                        );
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: moonsTable)" (
                            "id" INTEGER PRIMARY KEY,
                            "planet_id" INTEGER NOT NULL
                                REFERENCES "\#(unescaped: planetsTable)" ("id")
                        );
                        """#
                )

                do {
                    _ = try await connection.run(
                        query: #"""
                            INSERT INTO "\#(unescaped: moonsTable)"
                                ("id", "planet_id")
                            VALUES
                                (1, 999);
                            """#
                    )
                    Issue.record("Expected foreign key constraint violation.")
                }
                catch DatabaseError.query(let error) {
                    #expect(
                        String(reflecting: error)
                            .contains("violates foreign key constraint")
                    )
                }
                catch {
                    Issue.record("Expected database query error to be thrown.")
                }
            }
        }
    }

    @Test
    func tableCreation() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "galaxies_\(suffix)"

            try await database.withTransaction { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )

                try await connection.run(
                    query: #"""
                        CREATE TABLE IF NOT EXISTS "\#(unescaped: table)" (
                            "id" INTEGER PRIMARY KEY,
                            "name" TEXT
                        );
                        """#
                )

                let results = try await connection.run(
                    query: #"""
                        SELECT "tablename"
                        FROM "pg_tables"
                        WHERE "schemaname" = 'public'
                            AND "tablename" = '\#(unescaped: table)'
                        ORDER BY "tablename";
                        """#
                ) {
                    try await $0.collect()
                        .map {
                            try $0.decode(column: "tablename", as: String.self)
                        }
                }

                #expect(results.count == 1)
                #expect(results[0] == table)
            }
        }
    }

    @Test
    func tableInsert() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "galaxies_\(suffix)"

            try await database.withConnection { connection in
                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE IF NOT EXISTS "\#(unescaped: table)" (
                            "id" INTEGER PRIMARY KEY,
                            "name" TEXT
                        );
                        """#
                )

                let name1 = "Andromeda"
                let name2 = "Milky Way"

                struct GalaxyRow: Codable, Sendable {
                    let id: Int
                    let name: String

                    init(_ row: DatabaseRow) throws {
                        self.id = try row.decode(column: "id", as: Int.self)
                        self.name = try row.decode(
                            column: "name",
                            as: String.self
                        )
                    }
                }

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "name")
                        VALUES
                            (\#(1), \#(name1)),
                            (\#(2), \#(name2));
                        """#
                )

                let results = try await connection.run(
                    query: #"""
                        SELECT * FROM "\#(unescaped: table)" ORDER BY "name" ASC;
                        """#
                ) {
                    try await $0.collect()
                        .map {
                            try GalaxyRow($0)
                        }
                }

                #expect(results.count == 2)
                #expect(results[0].name == name1)
                #expect(results[1].name == name2)
            }

        }
    }

    @Test
    func rowDecoding() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "foo_\(suffix)"

            try await database.withConnection { connection in
                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" TEXT
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (1, 'abc'),
                            (2, NULL);
                        """#
                )

                struct FooRow: Codable, Sendable {
                    let id: Int
                    let value: String

                    init(_ row: DatabaseRow) throws {
                        self.id = try row.decode(column: "id", as: Int.self)
                        self.value = try row.decode(
                            column: "value",
                            as: String.self
                        )
                    }
                }

                let result = try await connection.run(
                    query: #"""
                        SELECT "id", "value"
                        FROM "\#(unescaped: table)"
                        ORDER BY "id";
                        """#
                ) { try await $0.collect() }

                #expect(result.count == 2)

                let item1 = result[0]
                let item2 = result[1]

                #expect(try item1.decode(column: "id", as: Int.self) == 1)
                #expect(try item2.decode(column: "id", as: Int.self) == 2)

                #expect(
                    try item1.decode(column: "id", as: Int?.self) == .some(1)
                )
                #expect(
                    (try? item1.decode(column: "value", as: Int?.self)) == nil
                )

                #expect(
                    try item1.decode(column: "value", as: String.self) == "abc"
                )
                #expect(
                    (try? item2.decode(column: "value", as: String.self)) == nil
                )

                #expect(
                    (try item1.decode(column: "value", as: String?.self))
                        == .some("abc")
                )
                #expect(
                    (try item2.decode(column: "value", as: String?.self))
                        == .none
                )
            }
        }
    }

    @Test
    func queryEncoding() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "foo_\(suffix)"

            try await database.withTransaction { connection in
                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )

                let row1: (Int, String?) = (1, "abc")
                let row2: (Int, String?) = (2, nil)

                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" TEXT
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (\#(row1.0), \#(row1.1)),
                            (\#(row2.0), \#(row2.1));
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "id", "value"
                            FROM "\#(unescaped: table)"
                            ORDER BY "id" ASC;
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 2)

                let item1 = result[0]
                let item2 = result[1]

                #expect(try item1.decode(column: "id", as: Int.self) == 1)
                #expect(try item2.decode(column: "id", as: Int.self) == 2)

                #expect(
                    try item1.decode(column: "value", as: String?.self) == "abc"
                )
                #expect(
                    try item2.decode(column: "value", as: String?.self) == nil
                )
            }
        }
    }

    @Test
    func unsafeSQLBindings() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "widgets_\(suffix)"

            try await database.withConnection { connection in
                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "name" TEXT NOT NULL
                        );
                        """#
                )

                let name = "gizmo"

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "name")
                        VALUES
                            (\#(1), \#(name));
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "name"
                            FROM "\#(unescaped: table)"
                            WHERE "id" = 1;
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)
                #expect(
                    try result[0].decode(column: "name", as: String.self)
                        == "gizmo"
                )
            }
        }
    }

    @Test
    func optionalStringInterpolationNil() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "notes_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "body" TEXT
                        );
                        """#
                )

                let body: String? = nil

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "body")
                        VALUES
                            (1, \#(body));
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "body"
                            FROM "\#(unescaped: table)"
                            WHERE "id" = 1;
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)
                #expect(
                    try result[0].decode(column: "body", as: String?.self)
                        == nil
                )
            }
        }
    }

    @Test
    func postgresDataInterpolation() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "tags_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "label" TEXT NOT NULL
                        );
                        """#
                )

                let label = "alpha"

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "label")
                        VALUES
                            (1, \#(label));
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "label"
                            FROM "\#(unescaped: table)"
                            WHERE "id" = 1;
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)
                #expect(
                    try result[0].decode(column: "label", as: String.self)
                        == "alpha"
                )
            }
        }
    }

    @Test
    func boundOptionalInterpolationRoundTrip() async throws {
        try await runUsingTestDatabaseClient { database in
            try await database.withConnection { connection in
                let boundString: String? = "alpha"
                let missingString: String? = nil
                let boundInt: Int? = 21
                let missingInt: Int? = nil
                let boundFloat: Float? = 1.25
                let missingFloat: Float? = nil
                let boundDouble: Double? = 3.75
                let missingDouble: Double? = nil
                let boundBool: Bool? = true
                let missingBool: Bool? = nil

                struct OptionalRow: Sendable {
                    let boundString: String?
                    let missingString: String?
                    let boundInt: Int?
                    let missingInt: Int?
                    let boundFloat: Double?
                    let missingFloat: Double?
                    let boundDouble: Double?
                    let missingDouble: Double?
                    let boundBool: Bool?
                    let missingBool: Bool?

                    init(_ row: DatabaseRow) throws {
                        self.boundString = try row.decode(
                            column: "bound_string",
                            as: String?.self
                        )
                        self.missingString = try row.decode(
                            column: "missing_string",
                            as: String?.self
                        )
                        self.boundInt = try row.decode(
                            column: "bound_int",
                            as: Int?.self
                        )
                        self.missingInt = try row.decode(
                            column: "missing_int",
                            as: Int?.self
                        )
                        self.boundFloat = try row.decode(
                            column: "bound_float",
                            as: Double?.self
                        )
                        self.missingFloat = try row.decode(
                            column: "missing_float",
                            as: Double?.self
                        )
                        self.boundDouble = try row.decode(
                            column: "bound_double",
                            as: Double?.self
                        )
                        self.missingDouble = try row.decode(
                            column: "missing_double",
                            as: Double?.self
                        )
                        self.boundBool = try row.decode(
                            column: "bound_bool",
                            as: Bool?.self
                        )
                        self.missingBool = try row.decode(
                            column: "missing_bool",
                            as: Bool?.self
                        )
                    }
                }

                let result = try await connection.run(
                    query: #"""
                        SELECT
                            (\#(boundString))::TEXT AS "bound_string",
                            (\#(missingString))::TEXT AS "missing_string",
                            (\#(boundInt))::INTEGER AS "bound_int",
                            (\#(missingInt))::INTEGER AS "missing_int",
                            (\#(boundFloat))::DOUBLE PRECISION AS "bound_float",
                            (\#(missingFloat))::DOUBLE PRECISION AS "missing_float",
                            (\#(boundDouble))::DOUBLE PRECISION AS "bound_double",
                            (\#(missingDouble))::DOUBLE PRECISION AS "missing_double",
                            (\#(boundBool))::BOOLEAN AS "bound_bool",
                            (\#(missingBool))::BOOLEAN AS "missing_bool";
                        """#
                ) { try await $0.collect().map { try OptionalRow($0) } }

                #expect(result.count == 1)
                #expect(result[0].boundString == "alpha")
                #expect(result[0].missingString == nil)
                #expect(result[0].boundInt == 21)
                #expect(result[0].missingInt == nil)
                #expect(result[0].boundFloat == 1.25)
                #expect(result[0].missingFloat == nil)
                #expect(result[0].boundDouble == 3.75)
                #expect(result[0].missingDouble == nil)
                #expect(result[0].boundBool == true)
                #expect(result[0].missingBool == nil)
            }
        }
    }

    @Test
    func unescapedOptionalInterpolationRoundTrip() async throws {
        try await runUsingTestDatabaseClient { database in
            try await database.withConnection { connection in
                let rawString: String? = "beta"
                let missingString: String? = nil
                let rawInt: Int? = 7
                let missingInt: Int? = nil
                let rawFloat: Float? = 2.5
                let missingFloat: Float? = nil
                let rawDouble: Double? = 4.5
                let missingDouble: Double? = nil
                let rawBool: Bool? = false
                let missingBool: Bool? = nil

                struct RawOptionalRow: Sendable {
                    let rawString: String?
                    let missingString: String?
                    let rawInt: Int?
                    let missingInt: Int?
                    let rawFloat: Double?
                    let missingFloat: Double?
                    let rawDouble: Double?
                    let missingDouble: Double?
                    let rawBool: Bool?
                    let missingBool: Bool?

                    init(_ row: DatabaseRow) throws {
                        self.rawString = try row.decode(
                            column: "raw_string",
                            as: String?.self
                        )
                        self.missingString = try row.decode(
                            column: "missing_string",
                            as: String?.self
                        )
                        self.rawInt = try row.decode(
                            column: "raw_int",
                            as: Int?.self
                        )
                        self.missingInt = try row.decode(
                            column: "missing_int",
                            as: Int?.self
                        )
                        self.rawFloat = try row.decode(
                            column: "raw_float",
                            as: Double?.self
                        )
                        self.missingFloat = try row.decode(
                            column: "missing_float",
                            as: Double?.self
                        )
                        self.rawDouble = try row.decode(
                            column: "raw_double",
                            as: Double?.self
                        )
                        self.missingDouble = try row.decode(
                            column: "missing_double",
                            as: Double?.self
                        )
                        self.rawBool = try row.decode(
                            column: "raw_bool",
                            as: Bool?.self
                        )
                        self.missingBool = try row.decode(
                            column: "missing_bool",
                            as: Bool?.self
                        )
                    }
                }

                let result = try await connection.run(
                    query: #"""
                        SELECT
                            '\#(unescaped: rawString)'::TEXT AS "raw_string",
                            \#(unescaped: missingString)::TEXT AS "missing_string",
                            \#(unescaped: rawInt)::INTEGER AS "raw_int",
                            \#(unescaped: missingInt)::INTEGER AS "missing_int",
                            \#(unescaped: rawFloat)::DOUBLE PRECISION AS "raw_float",
                            \#(unescaped: missingFloat)::DOUBLE PRECISION AS "missing_float",
                            \#(unescaped: rawDouble)::DOUBLE PRECISION AS "raw_double",
                            \#(unescaped: missingDouble)::DOUBLE PRECISION AS "missing_double",
                            \#(unescaped: rawBool)::BOOLEAN AS "raw_bool",
                            \#(unescaped: missingBool)::BOOLEAN AS "missing_bool";
                        """#
                ) { try await $0.collect().map { try RawOptionalRow($0) } }

                #expect(result.count == 1)
                #expect(result[0].rawString == "beta")
                #expect(result[0].missingString == nil)
                #expect(result[0].rawInt == 7)
                #expect(result[0].missingInt == nil)
                #expect(result[0].rawFloat == 2.5)
                #expect(result[0].missingFloat == nil)
                #expect(result[0].rawDouble == 4.5)
                #expect(result[0].missingDouble == nil)
                #expect(result[0].rawBool == false)
                #expect(result[0].missingBool == nil)
            }
        }
    }

    @Test
    func arrayInterpolationRoundTrip() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "array_samples_\(suffix)"

            try await database.withConnection { connection in
                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "name" TEXT NOT NULL,
                            "ratio" DOUBLE PRECISION NOT NULL,
                            "score" DOUBLE PRECISION NOT NULL,
                            "active" BOOLEAN NOT NULL
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "name", "ratio", "score", "active")
                        VALUES
                            (1, 'alpha', 1.5, 3.5, true),
                            (2, 'beta', 2.25, 4.75, false);
                        """#
                )

                let names = ["alpha", "omega"]
                let ids = [1, 99]
                let ratios: [Float] = [1.5, 9.5]
                let scores = [3.5, 9.75]
                let flags = [true, false]

                let result = try await connection.run(
                    query: #"""
                        SELECT
                            "id",
                            "name"
                        FROM "\#(unescaped: table)"
                        WHERE
                            "name" IN (\#(names))
                            AND "id" IN (\#(ids))
                            AND "ratio" IN (\#(ratios))
                            AND "score" IN (\#(scores))
                            AND "active" IN (\#(flags))
                        ORDER BY "id";
                        """#
                ) { try await $0.collect() }

                #expect(result.count == 1)
                #expect(try result[0].decode(column: "id", as: Int.self) == 1)
                #expect(
                    try result[0].decode(column: "name", as: String.self)
                        == "alpha"
                )
            }
        }
    }

    @Test
    func optionalArrayInterpolationRoundTrip() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "optional_array_samples_\(suffix)"

            try await database.withConnection { connection in
                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "name" TEXT NOT NULL,
                            "ratio" DOUBLE PRECISION NOT NULL,
                            "score" DOUBLE PRECISION NOT NULL,
                            "active" BOOLEAN NOT NULL
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "name", "ratio", "score", "active")
                        VALUES
                            (1, 'alpha', 1.5, 3.5, true),
                            (2, 'beta', 2.25, 4.75, false);
                        """#
                )

                let names: [String?] = ["alpha", nil, "omega"]
                let ids: [Int?] = [1, nil, 99]
                let ratios: [Float?] = [1.5, nil, 9.5]
                let scores: [Double?] = [3.5, nil, 9.75]
                let flags: [Bool?] = [true, nil, false]

                let result = try await connection.run(
                    query: #"""
                        SELECT
                            "id",
                            "name"
                        FROM "\#(unescaped: table)"
                        WHERE
                            "name" IN (\#(names))
                            AND "id" IN (\#(ids))
                            AND "ratio" IN (\#(ratios))
                            AND "score" IN (\#(scores))
                            AND "active" IN (\#(flags))
                        ORDER BY "id";
                        """#
                ) { try await $0.collect() }

                #expect(result.count == 1)
                #expect(try result[0].decode(column: "id", as: Int.self) == 1)
                #expect(
                    try result[0].decode(column: "name", as: String.self)
                        == "alpha"
                )
            }
        }
    }

    @Test
    func resultSequenceIterator() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "numbers_\(suffix)"

            try await database.withConnection { connection in
                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" TEXT NOT NULL
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (1, 'one'),
                            (2, 'two');
                        """#
                )

                let result = try await connection.run(
                    query: #"""
                        SELECT "id", "value"
                        FROM "\#(unescaped: table)"
                        ORDER BY "id";
                        """#
                ) { try await $0.collect() }

                #expect(result.count == 2)
                let first = result[0]
                let second = result[1]

                #expect(try first.decode(column: "id", as: Int.self) == 1)
                #expect(
                    try first.decode(column: "value", as: String.self) == "one"
                )

                #expect(try second.decode(column: "id", as: Int.self) == 2)
                #expect(
                    try second.decode(column: "value", as: String.self) == "two"
                )
            }
        }
    }

    @Test
    func collectFirstReturnsFirstRow() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "widgets_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" SERIAL PRIMARY KEY,
                            "name" TEXT NOT NULL
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("name")
                        VALUES
                            ('alpha'),
                            ('beta');
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "name"
                            FROM "\#(unescaped: table)"
                            ORDER BY "id" ASC;
                            """#
                    ) { try await $0.collect() }
                    .first

                #expect(result != nil)
                #expect(
                    try result?.decode(column: "name", as: String.self)
                        == "alpha"
                )
            }
        }
    }

    @Test
    func transactionSuccess() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "items_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "name" TEXT NOT NULL
                        );
                        """#
                )

                try await database.withTransaction { connection in
                    try await connection.run(
                        query: #"""
                            INSERT INTO "\#(unescaped: table)"
                                ("id", "name")
                            VALUES
                                (1, 'widget');
                            """#
                    )
                }

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "name"
                            FROM "\#(unescaped: table)"
                            WHERE "id" = 1;
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)
                #expect(
                    try result[0].decode(column: "name", as: String.self)
                        == "widget"
                )
            }
        }
    }

    @Test
    func transactionFailurePropagates() async throws {
        try await runUsingTestDatabaseClient { database in

            let suffix = randomTableSuffix()
            let table = "dummy_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "name" TEXT NOT NULL
                        );
                        """#
                )

                do {
                    _ = try await database.withTransaction { connection in
                        try await connection.run(
                            query: #"""
                                INSERT INTO "\#(unescaped: table)"
                                    ("id", "name")
                                VALUES
                                    (1, 'ok');
                                """#
                        )

                        return try await connection.run(
                            query: #"""
                                INSERT INTO "\#(unescaped: table)"
                                    ("id", "name")
                                VALUES
                                    (2, NULL);
                                """#
                        )
                    }
                    Issue.record(
                        "Expected database transaction error to be thrown."
                    )
                }
                catch DatabaseError.transaction(let error) {
                    #expect(error.beginError == nil)
                    #expect(error.closureError != nil)
                    #expect(
                        error.closureError.debugDescription.contains(
                            "null value in column"
                        )
                    )
                    #expect(error.rollbackError == nil)
                    #expect(error.commitError == nil)
                }
                catch {
                    Issue.record(
                        "Expected database transaction error to be thrown."
                    )
                }

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "id"
                            FROM "\#(unescaped: table)";
                            """#
                    ) { try await $0.collect() }

                #expect(result.isEmpty)
            }
        }
    }

    @Test
    func transactionClosureErrorPropagates() async throws {
        try await runUsingTestDatabaseClient { database in
            enum TestError: Error, Equatable {
                case boom
            }

            do {
                _ = try await database.withTransaction { _ in
                    throw TestError.boom
                }
                Issue.record("Expected transaction error to be thrown.")
            }
            catch DatabaseError.transaction(let error) {
                #expect(error.beginError == nil)
                #expect(error.commitError == nil)
                #expect(error.rollbackError == nil)
                #expect((error.closureError as? TestError) == .boom)
                #expect(error.file.isEmpty == false)
                #expect(error.line > 0)
            }
            catch {
                Issue.record(
                    "Expected database transaction error to be thrown."
                )
            }
        }
    }

    @Test
    func concurrentTransactionUpdates() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "sessions_\(suffix)"
            let sessionID = "session_\(suffix)"

            enum TestError: Error {
                case missingRow
            }

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" TEXT NOT NULL PRIMARY KEY,
                            "access_token" TEXT NOT NULL,
                            "access_expires_at" TIMESTAMPTZ NOT NULL,
                            "refresh_token" TEXT NOT NULL,
                            "refresh_count" INTEGER NOT NULL DEFAULT 0
                        );
                        """#
                )

                // set an expired token
                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "access_token", "access_expires_at", "refresh_token", "refresh_count")
                        VALUES
                            (
                                \#(sessionID),
                                'stale',
                                NOW() - INTERVAL '5 minutes',
                                'refresh',
                                0
                            );
                        """#
                )
            }

            func getValidAccessToken(sessionID: String) async throws -> String {
                try await database.withTransaction { connection in
                    let rows = try await connection.run(
                        query: #"""
                            SELECT
                                "access_token",
                                "refresh_count",
                                "access_expires_at" > NOW() + INTERVAL '60 seconds' AS "is_valid"
                            FROM "\#(unescaped: table)"
                            WHERE "id" = \#(sessionID)
                            FOR UPDATE;
                            """#
                    ) { try await $0.collect() }

                    guard let row = rows.first else {
                        throw TestError.missingRow
                    }

                    let isValid = try row.decode(
                        column: "is_valid",
                        as: Bool.self
                    )
                    if isValid {
                        // token was valid, must be called X times
                        return try row.decode(
                            column: "access_token",
                            as: String.self
                        )
                    }

                    // refresh, this branch can only be called 1 time
                    let refreshCount = try row.decode(
                        column: "refresh_count",
                        as: Int.self
                    )
                    let newRefreshCount = refreshCount + 1
                    let newToken = "token_\(newRefreshCount)"

                    try await Task.sleep(for: .milliseconds(40))

                    try await connection.run(
                        query: #"""
                            UPDATE "\#(unescaped: table)"
                            SET
                                "access_token" = \#(newToken),
                                "access_expires_at" = NOW() + INTERVAL '10 minutes',
                                "refresh_count" = \#(newRefreshCount)
                            WHERE "id" = \#(sessionID);
                            """#
                    )

                    return newToken
                }
            }

            let workerCount = 80
            var tokens: [String] = []
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        try await getValidAccessToken(sessionID: sessionID)
                    }
                }
                for try await token in group {
                    tokens.append(token)
                }
            }

            #expect(Set(tokens).count == 1)

            struct SessionRow: Codable, Sendable {
                let refreshCount: Int
                let accessToken: String
                let isValid: Bool

                init(_ row: DatabaseRow) throws {
                    self.refreshCount = try row.decode(
                        column: "refresh_count",
                        as: Int.self
                    )
                    self.accessToken = try row.decode(
                        column: "access_token",
                        as: String.self
                    )
                    self.isValid = try row.decode(
                        column: "is_valid",
                        as: Bool.self
                    )
                }
            }

            try await database.withConnection { connection in

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT
                                "access_token",
                                "refresh_count",
                                "access_expires_at" > NOW() AS "is_valid"
                            FROM "\#(unescaped: table)"
                            WHERE "id" = \#(sessionID);
                            """#,
                    ) {
                        try await $0.collect()
                            .map {
                                try SessionRow($0)
                            }
                    }

                #expect(result.count == 1)
                #expect(result[0].refreshCount == 1)
                #expect(result[0].accessToken == "token_1")
                #expect(result[0].isValid)
            }
        }
    }

    @Test
    func doubleRoundTrip() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "measurements_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" DOUBLE PRECISION NOT NULL
                        );
                        """#
                )

                let expected = 1.5

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (1, \#(expected));
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "value"
                            FROM "\#(unescaped: table)"
                            WHERE "id" = 1;
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)
                #expect(
                    try result[0].decode(column: "value", as: Double.self)
                        == expected
                )
            }
        }
    }

    @Test
    func missingColumnThrows() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "items_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" TEXT
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (1, 'abc');
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "id"
                            FROM "\#(unescaped: table)";
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)

                do {
                    _ = try result[0].decode(column: "value", as: String.self)
                    Issue.record("Expected decoding a missing column to throw.")
                }
                catch DecodingError.dataCorrupted {

                }
                catch {
                    Issue.record(
                        "Expected a dataCorrupted error for missing column."
                    )
                }
            }
        }
    }

    @Test
    func typeMismatchThrows() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "items_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" TEXT
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (1, 'abc');
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "value"
                            FROM "\#(unescaped: table)";
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)

                do {
                    _ = try result[0].decode(column: "value", as: Int.self)
                    Issue.record("Expected decoding a string as Int to throw.")
                }
                catch DecodingError.typeMismatch {

                }
                catch {
                    Issue.record(
                        "Expected a typeMismatch error when decoding a string as Int."
                    )
                }
            }
        }
    }

    @Test
    func nullDecodingThrowsTypeMismatch() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "nullable_values_\(suffix)"

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" INTEGER
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (1, NULL);
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "value"
                            FROM "\#(unescaped: table)";
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)

                do {
                    _ = try result[0].decode(column: "value", as: Int.self)
                    Issue.record("Expected decoding NULL as Int to throw.")
                }
                catch let DecodingError.typeMismatch(_, context) {
                    #expect(
                        context.debugDescription.contains(
                            "PostgresDecodingError"
                        )
                    )
                }
                catch {
                    Issue.record(
                        "Expected a typeMismatch error when decoding NULL as Int."
                    )
                }
            }
        }
    }

    @Test
    func nonPostgresDecodableTypeMismatch() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "custom_types_\(suffix)"

            struct CustomValue: Decodable, Sendable {
                let value: String
            }

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" TEXT NOT NULL
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (1, 'alpha');
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "value"
                            FROM "\#(unescaped: table)";
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)

                do {
                    _ = try result[0]
                        .decode(
                            column: "value",
                            as: CustomValue.self
                        )
                    Issue.record(
                        "Expected decoding non-PostgresDecodable type to throw."
                    )
                }
                catch let DecodingError.typeMismatch(_, context) {
                    #expect(
                        context.debugDescription.contains(
                            "Data is not convertible"
                        )
                    )
                }
                catch {
                    Issue.record(
                        "Expected a typeMismatch error for non-PostgresDecodable types."
                    )
                }
            }
        }
    }

    @Test
    func postgresRowDecodeMetatypeMismatch() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "metatype_mismatch_\(suffix)"

            func decodeWithMismatchedMetatype<T: Decodable, U: Decodable>(
                row: DatabaseRow,
                column: String,
                as _: T.Type,
                using _: U.Type
            ) throws -> T {
                // Force a mismatched metatype to exercise the guard cast failure.
                let mismatchedType = unsafeBitCast(U.self, to: T.Type.self)
                return try row.decode(column: column, as: mismatchedType)
            }

            try await database.withConnection { connection in

                try await connection.run(
                    query: #"""
                        DROP TABLE IF EXISTS "\#(unescaped: table)" CASCADE;
                        """#
                )
                try await connection.run(
                    query: #"""
                        CREATE TABLE "\#(unescaped: table)" (
                            "id" INTEGER NOT NULL PRIMARY KEY,
                            "value" TEXT NOT NULL
                        );
                        """#
                )

                try await connection.run(
                    query: #"""
                        INSERT INTO "\#(unescaped: table)"
                            ("id", "value")
                        VALUES
                            (1, 'abc');
                        """#
                )

                let result =
                    try await connection.run(
                        query: #"""
                            SELECT "value"
                            FROM "\#(unescaped: table)";
                            """#
                    ) { try await $0.collect() }

                #expect(result.count == 1)

                do {
                    _ = try decodeWithMismatchedMetatype(
                        row: result[0],
                        column: "value",
                        as: Int.self,
                        using: String.self
                    )
                    Issue.record(
                        "Expected mismatched metatype decode to throw."
                    )
                }
                catch let DecodingError.typeMismatch(_, context) {
                    #expect(
                        context.debugDescription.contains(
                            "Could not convert data"
                        )
                    )
                }
                catch {
                    Issue.record(
                        "Expected a typeMismatch error for metatype mismatch."
                    )
                }
            }
        }
    }

    @Test
    func queryFailureErrorText() async throws {
        try await runUsingTestDatabaseClient { database in
            let suffix = randomTableSuffix()
            let table = "missing_table_\(suffix)"

            try await database.withConnection { connection in

                do {
                    _ = try await connection.run(
                        query: #"""
                            SELECT *
                            FROM "\#(unescaped: table)";
                            """#
                    )
                    Issue.record("Expected query to fail for missing table.")
                }
                catch DatabaseError.query(let error) {
                    #expect(
                        String(reflecting: error).contains("does not exist")
                    )
                }
                catch {
                    Issue.record("Expected database query error to be thrown.")
                }
            }
        }
    }

    @Test
    func versionCheck() async throws {
        try await runUsingTestDatabaseClient { database in
            try await database.withConnection { connection in

                let result = try await connection.run(
                    query: #"""
                        SELECT
                            version() AS "version"
                        WHERE
                            1=\#(1);
                        """#
                ) { try await $0.collect() }

                #expect(result.count == 1)

                let item = result[0]
                let version = try item.decode(
                    column: "version",
                    as: String.self
                )
                #expect(version.contains("PostgreSQL"))
            }
        }
    }
}
