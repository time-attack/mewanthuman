//
//  ContentView.swift
//  number
//
//  Created by Sin Mat on 5/17/26.
//

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: – Model
// ---------------------------------------------------------------------------

struct Company: Identifiable {
    let id = UUID()
    let name: String
    let phone: String
    let icon: String
    let color: Color
    let secondaryColor: Color
}

let companies: [Company] = [
    Company(name: "Apple",         phone: "1-800-275-2273", icon: "apple.logo",                          color: .black,                              secondaryColor: .gray),
    Company(name: "Amazon",        phone: "1-888-280-4331", icon: "shippingbox.fill",                    color: Color(red: 1.0, green: 0.6, blue: 0.0),  secondaryColor: Color(red: 0.2, green: 0.2, blue: 0.2)),
    Company(name: "Google",        phone: "1-855-836-3987", icon: "magnifyingglass",                     color: Color(red: 0.26, green: 0.52, blue: 0.96), secondaryColor: Color(red: 0.86, green: 0.27, blue: 0.22)),
    Company(name: "Microsoft",     phone: "1-800-642-7676", icon: "square.grid.2x2.fill",               color: Color(red: 0.0, green: 0.47, blue: 0.84),  secondaryColor: Color(red: 0.49, green: 0.73, blue: 0.0)),
    Company(name: "Netflix",       phone: "1-888-638-3549", icon: "play.rectangle.fill",                color: Color(red: 0.89, green: 0.07, blue: 0.13), secondaryColor: Color(red: 0.1, green: 0.1, blue: 0.1)),
    Company(name: "Walmart",       phone: "1-800-925-6278", icon: "cart.fill",                          color: Color(red: 0.0, green: 0.4, blue: 0.82),   secondaryColor: Color(red: 1.0, green: 0.76, blue: 0.0)),
    Company(name: "Target",        phone: "1-800-440-0680", icon: "target",                             color: Color(red: 0.8, green: 0.0, blue: 0.0),    secondaryColor: .white),
    Company(name: "Costco",        phone: "1-800-774-2678", icon: "building.2.fill",                    color: Color(red: 0.0, green: 0.3, blue: 0.65),   secondaryColor: Color(red: 0.9, green: 0.15, blue: 0.15)),
    Company(name: "Nike",          phone: "1-800-806-6453", icon: "figure.run",                         color: Color(red: 0.96, green: 0.3, blue: 0.1),   secondaryColor: .black),
    Company(name: "Starbucks",     phone: "1-800-782-7282", icon: "cup.and.saucer.fill",               color: Color(red: 0.0, green: 0.4, blue: 0.24),   secondaryColor: .white),
    Company(name: "FedEx",         phone: "1-800-463-3339", icon: "airplane",                           color: Color(red: 0.3, green: 0.1, blue: 0.55),   secondaryColor: Color(red: 1.0, green: 0.4, blue: 0.0)),
    Company(name: "UPS",           phone: "1-800-742-5877", icon: "box.truck.fill",                     color: Color(red: 0.39, green: 0.2, blue: 0.04),  secondaryColor: Color(red: 1.0, green: 0.76, blue: 0.0)),
    Company(name: "Delta Airlines",phone: "1-800-221-1212", icon: "airplane.departure",                 color: Color(red: 0.0, green: 0.15, blue: 0.45),  secondaryColor: Color(red: 0.77, green: 0.1, blue: 0.18)),
    Company(name: "Bank of America",phone:"1-800-432-1000", icon: "banknote.fill",                      color: Color(red: 0.0, green: 0.27, blue: 0.55),  secondaryColor: Color(red: 0.82, green: 0.1, blue: 0.14)),
    Company(name: "Verizon",       phone: "1-800-922-0204", icon: "antenna.radiowaves.left.and.right",  color: Color(red: 0.8, green: 0.0, blue: 0.0),    secondaryColor: .black)
]

// ---------------------------------------------------------------------------
// MARK: – Actions
// ---------------------------------------------------------------------------

/// Dial the number immediately via the tel: URL scheme.
func callNumber(_ phone: String) {
    let digits = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    guard let url = URL(string: "tel:\(digits)") else { return }
    UIApplication.shared.open(url)
}

/// POST the phone number to your API as JSON.
/// Replace the endpoint string with your real URL.
func sendToAPI(_ phone: String, company: String = "") {
    guard let url = URL(string: "https://your-api.example.com/phone") else {
        print("[PhoneDirectory] Invalid API URL")
        return
    }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let payload: [String: Any] = [
        "phone_number": phone,
        "company": company,
        "timestamp": Date().timeIntervalSince1970
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    URLSession.shared.dataTask(with: request) { _, response, error in
        if let error {
            print("[PhoneDirectory] API error:", error.localizedDescription)
        } else if let http = response as? NSHTTPURLResponse {
            print("[PhoneDirectory] API responded \(http.statusCode) for \(phone)")
        }
    }.resume()
}

// ---------------------------------------------------------------------------
// MARK: – Views
// ---------------------------------------------------------------------------

struct CompanyLogoView: View {
    let company: Company

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [company.color, company.secondaryColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)

            Image(systemName: company.icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
    }
}

struct CompanyRow: View {
    let company: Company

    /// Controls the sheet that appears when tapping the phone number text.
    @State private var showDialog = false

    var body: some View {
        HStack(spacing: 16) {
            CompanyLogoView(company: company)

            VStack(alignment: .leading, spacing: 4) {
                Text(company.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                // Tapping the number opens the dialog instead of calling directly.
                Button(company.phone) {
                    showDialog = true
                }
                .font(.subheadline)
                .foregroundStyle(.blue)
                .buttonStyle(.plain)
            }

            Spacer()

            // Green call button – calls immediately, no dialog.
            Button {
                callNumber(company.phone)
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.green)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // Send-to-API button.
            Button {
                sendToAPI(company.phone, company: company.name)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.blue)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        // Long-press on the row also offers both options.
        .contextMenu {
            Button {
                callNumber(company.phone)
            } label: {
                Label("Call \(company.phone)", systemImage: "phone.fill")
            }

            Button {
                sendToAPI(company.phone, company: company.name)
            } label: {
                Label("Send to API", systemImage: "arrow.up.circle")
            }
        }
        // Dialog shown when the phone number text is tapped.
        .confirmationDialog(company.name, isPresented: $showDialog, titleVisibility: .visible) {
            Button("Call \(company.phone)") {
                callNumber(company.phone)
            }
            Button("Send to API") {
                sendToAPI(company.phone, company: company.name)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(company.phone)
        }
    }
}

struct ContentView: View {
    @State private var searchText = ""

    var filteredCompanies: [Company] {
        if searchText.isEmpty { return companies }
        return companies.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.phone.contains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredCompanies) { company in
                CompanyRow(company: company)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationTitle("Directory")
            .searchable(text: $searchText, prompt: "Search companies...")
        }
    }
}

#Preview {
    ContentView()
}
