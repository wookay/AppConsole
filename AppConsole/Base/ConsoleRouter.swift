//
//  ConsoleRouter.swift
//  ConsoleApp
//
//  Created by wookyoung on 3/13/16.
//  Copyright © 2016 factorcat. All rights reserved.
//

import UIKit
import Swifter

enum ChainType {
    case Go
    case Stop
}

enum TypeMatchType {
    case Match
    case None
}

typealias ChainResult = (ChainType, AnyObject?)
typealias TypeMatchResult = (TypeMatchType, AnyObject?)

public class ConsoleRouter {
    
    let type_handler = TypeHandler()
    var env = [String: AnyObject]()

    // MARK: ConsoleRouter - route
    func route(server: HttpServer, initial: AnyObject) {

        server["/"] = { req in
            let info = [String]()
            return self.result(info)
        }
        
        server["/initial"] = { req in
            let info = self.push_to_env(initial)
            return self.result(info)
        }
        
        server["/image"] = { req in
            for (name, value) in req.queryParams {
                if "path" == name {
                    let path = value.componentsSeparatedByString(".")
                    var lhs = [TypePair]()
                    for item in path {
                        if item.hasPrefix("0x") {
                            lhs.append(TypePair(first: "address", second: item))
                        } else {
                            lhs.append(TypePair(first: "symbol", second: item))
                        }
                    }

                    let (_,object) = self.chain(nil, lhs, full: true)
                    if let view = object as? UIView {
                        return self.result_image(view.to_data())
                    } else if let screen = object as? UIScreen {
                        return self.result_image(screen.to_data())
                    }
                }
            }

            return self.result_failed()
        }

        server["/query"] = { req in
            var query = [String: String]()
            do {
                let data = NSData(bytes: req.body, length: req.body.count)
                query = try NSJSONSerialization.JSONObjectWithData(data, options: .AllowFragments) as! [String : String]
            } catch {
            }

            if let type = query["type"], lhs = query["lhs"] {
                switch type {
                case "Getter":
                    let (success,object) = self.chain_getter(lhs)
                    if case .Go = success {
                        if let obj = object {
                            return self.result(obj)
                        } else {
                            return self.result_nil()
                        }
                    } else {
                        return self.result_failed()
                    }
                case "Setter":
                    if let rhs = query["rhs"] {
                        let (success, left) = self.chain(nil, self.json_parse(lhs), full: false)
                        let (_, value) = self.chain_getter(rhs)
                        if case .Go = success {
                            if let obj = left {
                                self.chain_setter(obj, lhs: lhs, value: value)
                                if let val = value {
                                    return self.result(val)
                                } else {
                                    return self.result_nil()
                                }
                            } else {
                                return self.result_nil()
                            }
                        } else {
                            return self.result_failed()
                        }
                    }
                default:
                    break
                }
            }
            return self.result_failed()
        }
    }
}



// MARK: ConsoleRouter - chains

extension ConsoleRouter {
    
    func chain_getter(lhs: String) -> ChainResult {
        let vec: [TypePair] = json_parse(lhs)
        return chain(nil, vec, full: true)
    }

    func chain_setter(obj: AnyObject, lhs: String, value: AnyObject?) -> AnyObject? {
        let vec: [TypePair] = json_parse(lhs)
        if let pair = vec.last {
            self.type_handler.setter_handle(obj, "set" + (pair.second as! String).uppercase_first() + ":", value: value)
        }
        return nil
    }

    func typepair_chain(obj: AnyObject?, pair: TypePair) -> ChainResult {
        switch pair.first {
        case "string":
            return (.Go, pair.second)
        case "int":
            return (.Go, ValueType(type: "q", value: pair.second))
        case "float":
            return (.Go, ValueType(type: "f", value: pair.second))
        case "bool":
            return (.Go, ValueType(type: "B", value: pair.second))
        case "address":
            return (.Go, from_env(pair.second as! String))
        case "symbol":
            if let str = pair.second as? String {
                switch str {
                case "nil":
                    return (.Stop, nil)
                default:
                    if let o = obj {
                        let (match, val) = type_handler.getter_handle(o, str)
                        switch match {
                        case .Match:
                            return (.Go, val)
                        case .None:
                            if swift_property_names(o).contains(str) {
                                return (.Go, swift_property_for_key(o, str))
                            } else {
                                for name in [str, str+":"] {
                                    if o.respondsToSelector(NSSelectorFromString(name)) {
                                        return (.Go, ValueType(type: "Function", value: "Function \(name)"))
                                    }
                                }
                                return (.Stop, nil)
                            }
                        }
                    }
                }
            }
            return (.Go, nil)
        case "call":
            if let nameargs = pair.second as? [AnyObject] {
                let (match, val) = typepair_callargs(obj, nameargs: nameargs)
                switch match {
                case .Match:
                    return (.Go, val)
                case .None:
                    return (.Stop, val)
                }
            } else {
                if let name = pair.second as? String {
                    if let o = obj {
                        if o is NSObject {
                            let (match, val) = type_handler.getter_handle(o, name)
                            switch match {
                            case .Match:
                                return (.Go, val)
                            case .None:
                                return (.Stop, val)
                            }
                        } else {
                            return (.Go, ValueType(type: "NonNSObject", value: "Needs subclass NSObject"))
                        }
                    }
                }
            }

        default:
            break
        }
        return (.Stop, nil)
    }

    func typepair_callargs(object: AnyObject?, nameargs: [AnyObject]) -> TypeMatchResult {
        if let name = nameargs.first as? String,
            let args = nameargs.last {
            if let obj = object {
                if let a = args as? [AnyObject] {
                    return type_handler.typepair_method(obj, name: name, a)
                } else {
                    return type_handler.typepair_method(obj, name: name, [])
                }
            } else {
                switch args {
                case is [Float]:
                    return type_handler.typepair_function(name, args as! [Float])
                case is [AnyObject]:
                    if let a = args as? [[AnyObject]] {
                        return type_handler.typepair_constructor(name, a)
                    }
                default:
                    break
                }
            }
        }
        return (.None, nil)
    }

    func chain_dictionary(dict: [String: AnyObject], _ key: String, _ nth: Int, _ vec: [TypePair], full: Bool) -> ChainResult {
        if let obj = dict[key] {
            return chain(obj, vec.slice_to_end(nth), full: full)
        } else {
            switch key {
            case "keys":
                return chain([String](dict.keys), vec.slice_to_end(nth), full: full)
            case "values":
                return chain([AnyObject](dict.values), vec.slice_to_end(nth), full: full)
            default:
                break
            }
        }
        return (.Stop, dict)
    }

    func chain_array(arr: [AnyObject], _ method: String, _ nth: Int, _ vec: [TypePair], full: Bool) -> ChainResult {
        switch method {
        case "sort":
            if let a = arr as? [String] {
                return chain(a.sort(<), vec.slice_to_end(nth), full: full)
            }
        case "first":
            return chain(arr.first, vec.slice_to_end(nth), full: full)
        case "last":
            return chain(arr.last, vec.slice_to_end(nth), full: full)
        default:
            break
        }
        return (.Stop, arr)
    }

    func chain(object: AnyObject?, _ vec: [TypePair], full: Bool) -> ChainResult {
        if let obj = object {
            let cnt = vec.count
            for (idx,pair) in vec.enumerate() {
                if !full && idx == cnt-1 {
                    continue
                }
                let (match, val) = typepair_chain(obj, pair: pair)
                if case .Go = match {
                    if let method = self.var_or_method(pair) {
                        switch method {
                        case is String:
                            let meth = method as! String
                            let (mat,ob) = type_handler.getter_handle(obj, meth)
                            if case .Match = mat {
                                if let o = ob {
                                    return chain(o, vec.slice_to_end(1), full: full)
                                } else {
                                    return (.Go, val)
                                }
                            } else if let dict = obj as? [String: AnyObject] {
                                return chain_dictionary(dict, meth, 1, vec, full: full)
                            } else if let arr = obj as? [AnyObject] {
                                return chain_array(arr, meth, 1, vec, full: full)
                            } else {
                                return (.Go, val)
                            }
                        case is Int:
                            if let arr = obj as? NSArray,
                                let idx = method as? Int {
                                if arr.count > idx {
                                    return chain(arr[idx], vec.slice_to_end(1), full: full)
                                }
                            }
                        default:
                            break
                        }
                    }
                    return (.Go, val)
                } else {
                    return (.Stop, obj)
                }
            }
            return (.Go, obj)
        } else {
            if let pair = vec.first {
                let (_, obj) = typepair_chain(nil, pair: pair)
                if let one = pair.second as? String {
                    if let c: AnyClass = NSClassFromString(one) {
                        return chain(c, vec.slice_to_end(1), full: full)
                    } else if env.keys.contains(one) {
                        return chain(env[one], vec.slice_to_end(1), full: full)
                    } else {
                        let (mat,constant) = type_handler.typepair_constant(one)
                        if case .Match = mat {
                            return (.Go, constant)
                        } else {
                            return (.Stop, obj)
                        }
                    }
                }
                return (.Go, obj)
            }
            return (.Go, object)
        }
    }
}

struct TypePair: CustomStringConvertible {
    var first: String
    var second: AnyObject
    var description: String {
        get {
            return "TypePair(\(first), \(second))"
        }
    }
}


// MARK: ConsoleRouter - utils

extension ConsoleRouter {

    public func register(name: String, object: AnyObject) {
        env[name] = object
    }
    
    func from_env(address: String) -> AnyObject? {
        return env[address]
    }
    
    func memoryof(obj: AnyObject) -> String {
        return NSString(format: "%p", unsafeBitCast(obj, Int.self)) as String
    }
    
    func push_to_env(obj: AnyObject) -> [String: String] {
        let address = memoryof(obj)
        env[address] = obj
        return ["address": address]
    }

    func var_or_method(pair: TypePair) -> AnyObject? {
        switch pair.second {
        case is String:
            if let str = pair.second as? String {
                if str.hasSuffix("()") {
                    let method = str.slice(0, to: str.characters.count - 2)
                    return method
                } else if let num = Int(str) {
                    return num
                } else {
                    return str
                }
            }
        case is Int:
            if let num = pair.second as? Int {
                return num
            }
        default:
            break
        }
        return nil
    }

    func typepairs(array: [[String: AnyObject]]) -> [TypePair] {
        var list = [TypePair]()
        for dict in array {
            if let k = dict["first"], let v = dict["second"] {
                list.append(TypePair(first: k as! String, second: v))
            }
        }
        return list
    }
    
    func json_parse(str: String?) -> [TypePair] {
        if let s = str {
            do {
                let json = try NSJSONSerialization.JSONObjectWithData(s.dataUsingEncoding(NSUTF8StringEncoding)!, options: NSJSONReadingOptions())
                if let j = json as? [[String: AnyObject]] {
                    return typepairs(j)
                }
            } catch {
            }
            return [TypePair(first: "raw", second: s)]
        } else {
            return [TypePair]()
        }
    }
}



// MARK: ConsoleRouter - result
extension ConsoleRouter {
    func result(value: AnyObject) -> HttpResponse {
        switch value {
        case is ValueType:
            if let val = value as? ValueType {
                switch val.type {
                case "Function":
                    return result_function(val.value)
                case "NonNSObject":
                    return result_non_nsobject(val.value)
                case "v":
                    return result_void()
                case "B":
                    return result_bool(val.value)
                case "{CGRect={CGPoint=dd}{CGSize=dd}}", "{CGRect={CGPoint=ff}{CGSize=ff}}":
                    return result_string(val.value)
                default:
                    if let num = val.value as? NSNumber {
                        if num.stringValue.containsString("e+") {
                            return result_any(String(num))
                        } else {
                            return result_any(num.floatValue)
                        }
                    } else {
                        return result_any(val.value)
                    }
                }
            }
        case is Int:
            return result_any(value)
        case is String:
            return result_string(value)
        case is UIView, is UIScreen:
            return .OK(.Json(["type": "view", "value": String(value)]))
        case is [String: AnyObject]:
            var d = [String: String]()
            for (k,v) in (value as! [String: AnyObject]) {
                d[k] = String(v)
            }
            return result_any(d)
        case is [AnyObject]:
            let a = (value as! [AnyObject]).map { x in String(x) }
            return result_any(a)
        default:
            break
        }
        return result_any(String(value))
    }

    func result_any(value: AnyObject) -> HttpResponse {
        return .OK(.Json(["type": "any", "value": value]))
    }

    func result_string(value: AnyObject) -> HttpResponse {
        return .OK(.Json(["type": "string", "value": value]))
    }

    func result_bool(value: AnyObject) -> HttpResponse {
        return .OK(.Json(["type": "bool", "value": value]))
    }

    func result_void() -> HttpResponse {
        return .OK(.Json(["type": "symbol", "value": "nothing"]))
    }

    func result_function(value: AnyObject) -> HttpResponse {
        return .OK(.Json(["type": "symbol", "value": value]))
    }

    func result_non_nsobject(value: AnyObject) -> HttpResponse {
        return .OK(.Json(["type": "symbol", "value": value]))
    }

    func result_image(imagedata: NSData?) -> HttpResponse {
        let headers = ["Content-Type": "image/png"]
        if let data = imagedata {
            let writer: (HttpResponseBodyWriter -> Void) = { writer in
                writer.write(Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(data.bytes), count: data.length)))
            }
            return .RAW(200, "OK", headers, writer)
        }
        return result_failed()
    }

    func result_nil() -> HttpResponse {
        return .OK(.Json(["type": "symbol", "value": "nothing"]))
    }

    func result_failed() -> HttpResponse {
        return .OK(.Json(["type": "symbol", "value": "Failed"]))
    }
}