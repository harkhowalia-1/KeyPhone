import Foundation
import WebKit
import Contacts
import UserNotifications

/// Shared part of the bridge between the phone shell (Web/index.html) and the
/// operating system. The page calls `window.PhoneHost.<name>(...)`, which posts
/// a message here; every call returns a Promise that `reply` resolves.
/// Platform subclasses handle calls, messages, photos, links and status.
class BridgeBase: NSObject, WKScriptMessageHandler {

    weak var webView: WKWebView?
    let store = CNContactStore()
    private var askedNotifications = false

    // MARK: page-side shim

    static func shim(platform: String) -> String {
        """
        (function(){var n=0,P={};
        window.__hostReply=function(id,ok,val){var p=P[id];if(!p)return;delete P[id];if(ok)p.res(val);else p.rej(new Error(val||'failed'))};
        function send(cmd,args){return new Promise(function(res,rej){var id=++n;P[id]={res:res,rej:rej};
          window.webkit.messageHandlers.host.postMessage({id:id,cmd:cmd,args:args||{}})})}
        window.PhoneHost={platform:'\(platform)',
          call:function(n){return send('call',{number:n})},
          sms:function(to,text){return send('sms',{to:to,text:text})},
          contacts:function(){return send('contacts')},
          saveContact:function(c){return send('saveContact',c)},
          deleteContact:function(id){return send('deleteContact',{id:id})},
          pickPhotos:function(){return send('pickPhotos')},
          camera:function(){return send('camera')},
          openUrl:function(u){return send('openUrl',{url:u})},
          haptic:function(k){return send('haptic',{kind:k})},
          schedule:function(items){return send('schedule',{items:items})},
          persist:function(json){return send('persist',{json:json})}};
        })();
        """
    }

    // MARK: saved phone state

    static var stateURL: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Larch K7", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.json")
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("state.json")
        #endif
    }

    /// Handed to the page before its script runs, so it starts with the saved phone.
    static func savedStateScript() -> String? {
        guard let json = try? String(contentsOf: stateURL, encoding: .utf8), json.hasPrefix("{") else { return nil }
        return "window.__LARCH_STATE=" + json + ";"
    }

    // MARK: messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = (body["id"] as? NSNumber)?.intValue,
              let cmd = body["cmd"] as? String else { return }
        let args = body["args"] as? [String: Any] ?? [:]
        if handlePlatform(cmd, id, args) { return }
        switch cmd {
        case "contacts": contacts(id)
        case "saveContact": saveContact(id, args)
        case "deleteContact": deleteContact(id, args["id"] as? String ?? "")
        case "schedule": schedule(id, args["items"] as? [[String: Any]] ?? [])
        case "persist": persist(id, args["json"] as? String ?? "")
        default: reply(id, "Not available on this device", ok: false)
        }
    }

    /// Subclasses handle platform commands here and return true when they did.
    func handlePlatform(_ cmd: String, _ id: Int, _ args: [String: Any]) -> Bool { false }

    func reply(_ id: Int, _ value: Any? = nil, ok: Bool = true) {
        var literal = "null"
        if let value = value,
           let data = try? JSONSerialization.data(withJSONObject: [value]),
           let text = String(data: data, encoding: .utf8) {
            literal = String(text.dropFirst().dropLast())
        }
        evaluate("window.__hostReply(\(id),\(ok),\(literal))")
    }

    func evaluate(_ js: String) {
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js) }
    }

    // MARK: Contacts

    static let contactKeys: [CNKeyDescriptor] = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey
    ].map { $0 as CNKeyDescriptor }

    private func withContactsAccess(_ id: Int, _ work: @escaping () -> Void) {
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else {
                return self.reply(id, "Contacts access is off. Turn it on in Settings › Privacy › Contacts.", ok: false)
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    private func contacts(_ id: Int) {
        withContactsAccess(id) {
            var out: [[String: Any]] = []
            let request = CNContactFetchRequest(keysToFetch: Self.contactKeys)
            request.sortOrder = .userDefault
            do {
                try self.store.enumerateContacts(with: request) { c, _ in
                    var name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    if name.isEmpty { name = c.organizationName }
                    var item: [String: Any] = ["id": c.identifier, "name": name]
                    for phone in c.phoneNumbers {
                        let value = phone.value.stringValue
                        let label = phone.label
                        if label == CNLabelHome {
                            if item["home"] == nil { item["home"] = value }
                        } else if label == CNLabelWork {
                            if item["work"] == nil { item["work"] = value }
                        } else if item["num"] == nil {
                            item["num"] = value
                        }
                    }
                    if item["num"] == nil { item["num"] = item["home"] ?? item["work"] ?? "" }
                    if let email = c.emailAddresses.first { item["email"] = email.value as String }
                    if !name.isEmpty { out.append(item) }
                }
                self.reply(id, out)
            } catch {
                self.reply(id, error.localizedDescription, ok: false)
            }
        }
    }

    private func saveContact(_ id: Int, _ args: [String: Any]) {
        withContactsAccess(id) {
            let request = CNSaveRequest()
            let contact: CNMutableContact
            var isNew = false
            if let cid = args["id"] as? String,
               let existing = try? self.store.unifiedContact(withIdentifier: cid, keysToFetch: Self.contactKeys),
               let copy = existing.mutableCopy() as? CNMutableContact {
                contact = copy
            } else {
                contact = CNMutableContact()
                isNew = true
            }

            let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
            contact.givenName = parts.first ?? ""
            contact.familyName = parts.count > 1 ? parts[1] : ""

            // Change only the numbers the phone manages; keep any others.
            var phones = contact.phoneNumbers
            func setPhone(_ key: String, matches: (String?) -> Bool, label: String) {
                let value = (args[key] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let index = phones.firstIndex { matches($0.label) }
                if value.isEmpty {
                    if let i = index { phones.remove(at: i) }
                } else if let i = index {
                    phones[i] = phones[i].settingValue(CNPhoneNumber(stringValue: value))
                } else {
                    phones.append(CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: value)))
                }
            }
            setPhone("num", matches: { $0 != CNLabelHome && $0 != CNLabelWork }, label: CNLabelPhoneNumberMobile)
            setPhone("home", matches: { $0 == CNLabelHome }, label: CNLabelHome)
            setPhone("work", matches: { $0 == CNLabelWork }, label: CNLabelWork)
            contact.phoneNumbers = phones

            let email = (args["email"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var emails = contact.emailAddresses
            if email.isEmpty {
                if !emails.isEmpty { emails.removeFirst() }
            } else if emails.isEmpty {
                emails.append(CNLabeledValue(label: CNLabelHome, value: email as NSString))
            } else {
                emails[0] = emails[0].settingValue(email as NSString)
            }
            contact.emailAddresses = emails

            if isNew { request.add(contact, toContainerWithIdentifier: nil) } else { request.update(contact) }
            do {
                try self.store.execute(request)
                self.reply(id, contact.identifier)
            } catch {
                self.reply(id, error.localizedDescription, ok: false)
            }
        }
    }

    private func deleteContact(_ id: Int, _ cid: String) {
        withContactsAccess(id) {
            guard let existing = try? self.store.unifiedContact(withIdentifier: cid, keysToFetch: Self.contactKeys),
                  let copy = existing.mutableCopy() as? CNMutableContact else {
                return self.reply(id, true)
            }
            let request = CNSaveRequest()
            request.delete(copy)
            do { try self.store.execute(request); self.reply(id, true) }
            catch { self.reply(id, error.localizedDescription, ok: false) }
        }
    }

    // MARK: alarms, reminders and timers as system notifications

    private func schedule(_ id: Int, _ items: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        let apply = {
            center.getPendingNotificationRequests { pending in
                let ours = pending.map(\.identifier).filter { $0.hasPrefix("larch-") }
                center.removePendingNotificationRequests(withIdentifiers: ours)
                for item in items {
                    guard let key = item["id"] as? String else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = item["title"] as? String ?? "Larch K7"
                    content.body = item["body"] as? String ?? ""
                    content.sound = .default
                    var trigger: UNNotificationTrigger?
                    if let at = (item["at"] as? NSNumber)?.doubleValue {
                        let date = Date(timeIntervalSince1970: at / 1000)
                        guard date > Date() else { continue }
                        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                        trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                    } else if let hour = (item["hour"] as? NSNumber)?.intValue,
                              let minute = (item["minute"] as? NSNumber)?.intValue {
                        var parts = DateComponents()
                        parts.hour = hour
                        parts.minute = minute
                        if let weekday = (item["weekday"] as? NSNumber)?.intValue { parts.weekday = weekday }
                        trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: (item["repeats"] as? Bool) ?? false)
                    }
                    guard let t = trigger else { continue }
                    center.add(UNNotificationRequest(identifier: "larch-" + key, content: content, trigger: t))
                }
                self.reply(id, true)
            }
        }
        if askedNotifications || items.isEmpty {
            apply()
        } else {
            askedNotifications = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in apply() }
        }
    }

    // MARK: saving the phone

    private func persist(_ id: Int, _ json: String) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try json.write(to: Self.stateURL, atomically: true, encoding: .utf8)
                self.reply(id, true)
            } catch {
                self.reply(id, error.localizedDescription, ok: false)
            }
        }
    }
}
