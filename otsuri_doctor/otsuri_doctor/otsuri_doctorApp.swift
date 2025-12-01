//
//  otsuri_doctorApp.swift
//  otsuri_doctor
//
//  Created by 坂井泰吾 on 2025/12/02.
//

import SwiftUI
import CoreData

@main
struct otsuri_doctorApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
