import SwiftUI

/// «No pudimos leer 2 correos · Reintentar».
///
/// Un correo del banco que no se pudo descargar es un gasto que falta, y en
/// una app que tiene que cuadrar con el banco eso no puede quedarse sólo en
/// Diagnóstico. Se reintenta solo en cada lectura; esto lo hace visible y deja
/// forzarlo. Vista propia, y no dentro del Resumen, para que el progreso de
/// cada lectura no redibuje la pantalla entera.
struct FailedEmailsBanner: View {
    @ObservedObject private var gmailSync = GmailSyncService.shared
    @ObservedObject private var gmailAuth = GmailAuthService.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    @Environment(\.modelContext) private var modelContext

    /// Dentro del cuerpo: aplicada desde fuera dejaría el hueco aunque no
    /// haya aviso.
    var bottomPadding: CGFloat = 0

    private var palette: Palette { Palette(scheme).themed(proTheme) }
    private var count: Int { gmailSync.failedEmailCount }

    var body: some View {
        if gmailAuth.isAuthenticated && count > 0 {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "No pudimos leer 1 correo del banco"
                                    : "No pudimos leer \(count) correos del banco")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text("Puede faltar algún gasto. Lo reintentamos solos.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 8)
                if gmailSync.isSyncing {
                    ProgressView()
                } else {
                    Button("Reintentar") {
                        gmailSync.modelContext = modelContext
                        gmailSync.retryFailedEmails()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5))
            .accessibilityElement(children: .combine)
            .padding(.bottom, bottomPadding)
        }
    }
}
