/// Commands the chrome (sidebar, menu, shortcuts) can send to a browser pane.
@MainActor
protocol BrowserCommands: AnyObject {
    func navigate(to input: String)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
}
