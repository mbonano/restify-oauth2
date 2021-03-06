"use strict"

require("chai").use(require("sinon-chai"))
sinon = require("sinon")
should = require("chai").should()
Assertion = require("chai").Assertion
restify = require("restify")
restifyOAuth2 = require("..")

tokenEndpoint = "/token-uri"
wwwAuthenticateRealm = "Realm string"
tokenExpirationTime = 12345

Assertion.addMethod("unauthorized", (message) ->
    expectedLink = "<#{tokenEndpoint}>; rel=\"oauth2-token\"; grant-types=\"password\"; token-types=\"bearer\"";

    @_obj.header.should.have.been.calledWith("WWW-Authenticate", "Bearer realm=\"#{wwwAuthenticateRealm}\"")
    @_obj.header.should.have.been.calledWith("Link", expectedLink)
    @_obj.send.should.have.been.calledOnce
    @_obj.send.should.have.been.calledWith(sinon.match.instanceOf(restify.UnauthorizedError))
    @_obj.send.should.have.been.calledWith(sinon.match.has("message", sinon.match(message)))
)

Assertion.addMethod("oauthError", (errorClass, errorType, errorDescription) ->
    desiredBody = { error: errorType, error_description: errorDescription }
    @_obj.send.should.have.been.calledOnce
    @_obj.send.should.have.been.calledWith(sinon.match.instanceOf(restify[errorClass + "Error"]))
    @_obj.send.should.have.been.calledWith(sinon.match.has("message", errorDescription))
    @_obj.send.should.have.been.calledWith(sinon.match.has("body", desiredBody))
)

beforeEach ->
    @req = { pause: sinon.spy(), resume: sinon.spy(), username: "anonymous", authorization: {} }
    @res = { header: sinon.spy(), send: sinon.spy() }
    @next = sinon.spy((x) => if x? then @res.send(x))

    @server =
        post: sinon.spy((path, handler) => @postToTokenEndpoint = => handler(@req, @res, @next))
        use: (plugin) => plugin(@req, @res, @next)

    @authenticateToken = sinon.stub()
    @validateClient = sinon.stub()
    @grantUserToken = sinon.stub()

    options = {
        tokenEndpoint
        wwwAuthenticateRealm
        tokenExpirationTime
        hooks: {
            @authenticateToken
            @validateClient
            @grantUserToken
        }
    }

    @doIt = => restifyOAuth2.ropc(@server, options)

describe "Resource Owner Password Credentials flow", ->
    it "should set up the token endpoint", ->
        @doIt()

        @server.post.should.have.been.calledWith(tokenEndpoint)

    describe "For POST requests to the token endpoint", ->
        beforeEach ->
            @req.method = "POST"
            @req.path = => tokenEndpoint

            baseDoIt = @doIt
            @doIt = =>
                baseDoIt()
                @postToTokenEndpoint()

        describe "with a body", ->
            beforeEach -> @req.body = {}

            describe "that has grant_type=password", ->
                beforeEach -> @req.body.grant_type = "password"

                describe "and has a username field", ->
                    beforeEach ->
                        @username = "username123"
                        @req.body.username = @username

                    describe "and a password field", ->
                        beforeEach ->
                            @password = "password456"
                            @req.body.password = @password

                        describe "with a basic access authentication header", ->
                            beforeEach ->
                                [@clientId, @clientSecret] = ["clientId123", "clientSecret456"]
                                @req.authorization =
                                    scheme: "Basic"
                                    basic: { username: @clientId, password: @clientSecret }

                            it "should validate the client, with client ID/secret from the basic authentication", ->
                                @doIt()

                                @validateClient.should.have.been.calledWith(@clientId, @clientSecret)

                            describe "when `validateClient` calls back with `true`", ->
                                beforeEach -> @validateClient.yields(null, true)

                                it "should use the username and password body fields to grant a token", ->
                                    @doIt()

                                    @grantUserToken.should.have.been.calledWith(@username, @password)

                                describe "when `grantUserToken` calls back with a token", ->
                                    beforeEach ->
                                        @token = "token123"
                                        @grantUserToken.yields(null, @token)

                                    it "should send a response with access_token, token_type, and expires_in set", ->
                                        @doIt()

                                        @res.send.should.have.been.calledWith(
                                            access_token: @token,
                                            token_type: "Bearer"
                                            expires_in: tokenExpirationTime
                                        )

                                describe "when `grantUserToken` calls back with `false`", ->
                                    beforeEach -> @grantUserToken.yields(null, false)

                                    it "should send a 401 response with error_type=invalid_client", ->
                                        @doIt()

                                        @res.should.be.an.oauthError("Unauthorized", "invalid_client",
                                                                     "Username and password did not authenticate.")

                                describe "when `grantUserToken` calls back with `null`", ->
                                    beforeEach -> @grantUserToken.yields(null, null)

                                    it "should send a 401 response with error_type=invalid_client", ->
                                        @doIt()

                                        @res.should.be.an.oauthError("Unauthorized", "invalid_client",
                                                                     "Username and password did not authenticate.")

                                describe "when `grantUserToken` calls back with an error", ->
                                    beforeEach ->
                                        @error = new Error("Bad things happened, internally.")
                                        @grantUserToken.yields(@error)

                                    it "should call `next` with that error", ->
                                        @doIt()

                                        @next.should.have.been.calledWithExactly(@error)

                            describe "when `validateClient` calls back with `false`", ->
                                beforeEach -> @validateClient.yields(null, false)

                                it "should send a 401 response with error_type=invalid_client and a WWW-Authenticate " +
                                   "header", ->
                                    @doIt()

                                    @res.header.should.have.been.calledWith(
                                        "WWW-Authenticate",
                                        'Basic realm="Client ID and secret did not validate."'
                                    )
                                    @res.should.be.an.oauthError("Unauthorized", "invalid_client",
                                                                 "Client ID and secret did not validate.")

                                it "should not call the `grantUserToken` hook", ->
                                    @doIt()

                                    @grantUserToken.should.not.have.been.called

                            describe "when `validateClient` calls back with an error", ->
                                beforeEach ->
                                    @error = new Error("Bad things happened, internally.")
                                    @validateClient.yields(@error)

                                it "should call `next` with that error", ->
                                    @doIt()

                                    @next.should.have.been.calledWithExactly(@error)

                                it "should not call the `grantUserToken` hook", ->
                                    @doIt()

                                    @grantUserToken.should.not.have.been.called

                        describe "without an authorization header", ->
                            it "should send a 400 response with error_type=invalid_request", ->
                                @doIt()

                                @res.should.be.an.oauthError("BadRequest", "invalid_request",
                                                             "Must include a basic access authentication header.")

                            it "should not call the `validateClient` or `grantUserToken` hooks", ->
                                @doIt()

                                @validateClient.should.not.have.been.called
                                @grantUserToken.should.not.have.been.called

                        describe "with an authorization header that does not contain basic access credentials", ->
                            beforeEach ->
                                @req.authorization =
                                    scheme: "Bearer"
                                    credentials: "asdf"

                            it "should send a 400 response with error_type=invalid_request", ->
                                @doIt()

                                @res.should.be.an.oauthError("BadRequest", "invalid_request",
                                                             "Must include a basic access authentication header.")

                            it "should not call the `validateClient` or `grantUserToken` hooks", ->
                                @doIt()

                                @validateClient.should.not.have.been.called
                                @grantUserToken.should.not.have.been.called

                    describe "that has no password field", ->
                        beforeEach -> @req.body.password = null

                        it "should send a 400 response with error_type=invalid_request", ->
                            @doIt()

                            @res.should.be.an.oauthError("BadRequest", "invalid_request",
                                                         "Must specify password field.")

                        it "should not call the `validateClient` or `grantUserToken` hooks", ->
                            @doIt()

                            @validateClient.should.not.have.been.called
                            @grantUserToken.should.not.have.been.called

                describe "that has no username field", ->
                    beforeEach -> @req.body.username = null

                    it "should send a 400 response with error_type=invalid_request", ->
                        @doIt()

                        @res.should.be.an.oauthError("BadRequest", "invalid_request", "Must specify username field.")

                    it "should not call the `validateClient` or `grantUserToken` hooks", ->
                        @doIt()

                        @validateClient.should.not.have.been.called
                        @grantUserToken.should.not.have.been.called

            describe "that has grant_type=authorization_code", ->
                beforeEach -> @req.body.grant_type = "authorization_code"

                it "should send a 400 response with error_type=unsupported_grant_type", ->
                    @doIt()

                    @res.should.be.an.oauthError("BadRequest", "unsupported_grant_type",
                                                 "Only grant_type=password is supported.")

                it "should not call the `validateClient` or `grantUserToken` hooks", ->
                    @doIt()

                    @validateClient.should.not.have.been.called
                    @grantUserToken.should.not.have.been.called

            describe "that has no grant_type value", ->
                it "should send a 400 response with error_type=invalid_request", ->
                    @doIt()

                    @res.should.be.an.oauthError("BadRequest", "invalid_request", "Must specify grant_type field.")

                it "should not call the `validateClient` or `grantUserToken` hooks", ->
                    @doIt()

                    @validateClient.should.not.have.been.called
                    @grantUserToken.should.not.have.been.called

        describe "without a body", ->
            beforeEach -> @req.body = null

            it "should send a 400 response with error_type=invalid_request", ->
                @doIt()

                @res.should.be.an.oauthError("BadRequest", "invalid_request", "Must supply a body.")

            it "should not call the `validateClient` or `grantUserToken` hooks", ->
                @doIt()

                @validateClient.should.not.have.been.called
                @grantUserToken.should.not.have.been.called

        describe "without a body that has been parsed into an object", ->
            beforeEach -> @req.body = "Left as a string or buffer or something"

            it "should send a 400 response with error_type=invalid_request", ->
                @doIt()

                @res.should.be.an.oauthError("BadRequest", "invalid_request", "Must supply a body.")

            it "should not call the `validateClient` or `grantUserToken` hooks", ->
                @doIt()

                @validateClient.should.not.have.been.called
                @grantUserToken.should.not.have.been.called

    describe "For other requests", ->
        beforeEach -> @req.path = => "/other-resource"

        describe "with an authorization header that contains a valid bearer token", ->
            beforeEach ->
                @token = "TOKEN123"
                @req.authorization = { scheme: "Bearer", credentials: @token }

            it "should pause the request and authenticate the token", ->
                @doIt()

                @req.pause.should.have.been.called
                @authenticateToken.should.have.been.calledWith(@token)

            describe "when the `authenticateToken` calls back with a username", ->
                beforeEach ->
                    @username = "user123"
                    @authenticateToken.yields(null, @username)

                it "should resume the request, set the `username` property on the request, and call `next`", ->
                    @doIt()

                    @req.resume.should.have.been.called
                    @req.should.have.property("username", @username)
                    @next.should.have.been.calledWithExactly()

            describe "when the `authenticateToken` calls back with `false`", ->
                beforeEach -> @authenticateToken.yields(null, false)

                it "should resume the request and send a 401 response, along with WWW-Authenticate and Link headers", ->
                    @doIt()

                    @req.resume.should.have.been.called
                    @res.should.be.unauthorized("Bearer token invalid.")

            describe "when the `authenticateToken` calls back with a 401 error", ->
                beforeEach ->
                    @errorMessage = "The authentication failed for some reason."
                    @authenticateToken.yields(new restify.UnauthorizedError(@errorMessage))

                it "should resume the request and send the error, along with WWW-Authenticate and Link headers", ->
                    @doIt()

                    @req.resume.should.have.been.called
                    @res.should.be.unauthorized(@errorMessage)

            describe "when the `authenticateToken` calls back with a non-401 error", ->
                beforeEach ->
                    @error = new restify.ForbiddenError("The authentication succeeded but this resource is forbidden.")
                    @authenticateToken.yields(@error)

                it "should resume the request and send the error, but no headers", ->
                    @doIt()

                    @req.resume.should.have.been.called
                    @res.send.should.have.been.calledWith(@error)
                    @res.header.should.not.have.been.called

        describe "without an authorization header", ->
            beforeEach -> @req.authorization = {}

            it "should remove `req.username`, and simply call `next`", ->
                @doIt()

                should.not.exist(@req.username)
                @next.should.have.been.calledWithExactly()

        describe "with an authorization header that does not contain a bearer token", ->
            beforeEach ->
                @req.authorization =
                    scheme: "basic"
                    credentials: "asdf"
                    basic: { username: "aaa", password: "bbb" }

            it "should send a 401 response with WWW-Authenticate and Link headers", ->
                @doIt()

                @res.should.be.unauthorized("Bearer token required.")

        describe "with an authorization header that contains an empty bearer token", ->
            beforeEach ->
                @req.authorization =
                    scheme: "Bearer"
                    credentials: ""

            it "should send a 401 response with WWW-Authenticate and Link headers", ->
                @doIt()

                @res.should.be.unauthorized("Bearer token required.")

    describe "`res.sendUnauthorized`", ->
        beforeEach -> @doIt()

        describe "with no arguments", ->
            beforeEach -> @res.sendUnauthorized()

            it "should send a 401 response with WWW-Authenticate and Link headers, plus the default message", ->
                @res.should.be.unauthorized("Bearer token required.")

        describe "with a message passed", ->
            message = "You really should go get a bearer token"
            beforeEach -> @res.sendUnauthorized(message)

            it "should send a 401 response with WWW-Authenticate and Link headers, plus the specified message", ->
                @res.should.be.unauthorized(message)
