//
//  DatabaseTransactionErrorPostgres.swift
//  feather-database-postgres
//
//  Created by Tibor Bödecs on 2026. 02. 02..
//

import FeatherDatabase
import PostgresNIO

public struct DatabaseTransactionErrorPostgres: DatabaseTransactionError {

    public let file: String
    public let line: Int
    public let beginError: (any Error)?
    public let closureError: (any Error)?
    public let commitError: (any Error)?
    public let rollbackError: (any Error)?

    init(
        file: String = #fileID,
        line: Int = #line,
        beginError: (any Error)? = nil,
        closureError: (any Error)? = nil,
        commitError: (any Error)? = nil,
        rollbackError: (any Error)? = nil
    ) {
        self.file = file
        self.line = line
        self.beginError = beginError
        self.closureError = closureError
        self.commitError = commitError
        self.rollbackError = rollbackError
    }

    init(
        underlyingError: PostgresTransactionError
    ) {
        self.file = underlyingError.file
        self.line = underlyingError.line
        self.beginError = underlyingError.beginError
        self.closureError = underlyingError.closureError
        self.commitError = underlyingError.commitError
        self.rollbackError = underlyingError.rollbackError
    }
}
