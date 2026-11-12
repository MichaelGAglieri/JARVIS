import Foundation

@main
struct Tests {
    static func main() throws {
        var count = 0
        func expect(_ phrase: String, _ value: RobotVoiceCommand?, front: Bool = false) {
            precondition(RobotVoiceCommand.parse(phrase, consoleInFront: front) == value, "Unexpected parse: \(phrase)")
            count += 1
        }
        expect("Jarvis, abilita il robot.", .enable)
        expect("abilita i robot", .enable)
        expect("protocollo robot", .enable)
        expect("chiudi Robot Console", .close)
        expect("chiudi l'applicazione", nil)
        expect("chiudi l'applicazione", .close, front: true)
        expect("chiudi Safari", nil, front: true)
        expect("fai sequenza", .sequence(nil))
        expect("fai la sequenza", .sequence(nil))
        expect("esegui la sequenza allineamento 1", .sequence("allineamento 1"))
        expect("Muovi J1 di 20 gradi", .joint(1,20,absolute:false))
        expect("Muovi il giunto J2 di meno venti gradi", .joint(2,-20,absolute:false))
        expect("sposta J 3 di -2,5 gradi", .joint(3,-2.5,absolute:false))
        expect("porta J1 a 20 gradi", .joint(1,20,absolute:true))
        expect("ruota giunto due di trenta gradi", .joint(2,30,absolute:false))
        expect("porta J1 a ventitré gradi", .joint(1,23,absolute:true))
        expect("puoi spiegarmi come muovi J1 di 20 gradi", nil)
        expect("non muovere J1 di 20 gradi", nil)
        expect("muovi J7 di 20 gradi", nil)
        expect("muovi J1 di nan gradi", nil)
        expect("muovi J1 di 400 gradi", nil)
        expect("muovi J1 di 20 gradi e J2 di 10 gradi", nil)
        expect("muovi J1 di 20 o 30 gradi", nil)
        expect("muovi J1 di venti cinque gradi", nil)
        expect("come si abilita il robot", nil)
        expect("Jarvis, Abilità Robot.", .enable)
        expect("E segui sequenzo.", .sequence(nil))
        expect("segui sequenza", .sequence(nil))
        expect("ESEGUI SEQUENZA.", .sequence(nil))
        expect("segui le istruzioni", nil)
        expect("Jarvis torna a Dom.", .home)
        expect("torna a home", .home)
        expect("vai in posizione home", .home)
        expect("riporta il robot a home", .home)
        expect("torna a casa", nil)
        expect("come si torna a home", nil)
        func stop(_ text: String, _ wanted: Bool, echo: String? = nil) {
            precondition(RobotVoiceCommand.isMotionStop(text, echo: echo) == wanted, "stop: \(text)")
            count += 1
        }
        stop("Stop!", true); stop(" Basta.", true); stop("Fermati!", true); stop("ferma il robot", true)
        stop("Jarvis, stop.", true); stop("Alt!", true); stop("Stop stop stop", true); stop("FERMO", true)
        stop("non fermarti", false); stop("Grazie.", false); stop("Sequenza avviata, signore.", false)
        stop("alto", false); stop("fermata dell'autobus", false); stop("allineamento 2 e presa", false)
        stop("stop", false, echo: "STOP inviato, signore.")
        stop("non è ancora il momento di dire basta adesso però va bene così", false)
        print("PASS: \(count) voice parser cases")
        if CommandLine.arguments.count == 2 {
            let path = CommandLine.arguments[1]
            let result = try RobotOperatorChannel.exchange(path: path, payload: Data("{\"op\":\"status\"}\n".utf8))
            let status = try JSONSerialization.jsonObject(with: result) as! [String:Any]
            precondition(status["ok"] as? Bool == true && status["version"] as? Int == 1)
            print("PASS: Swift ↔ Python private Unix socket")
        }
    }
}
